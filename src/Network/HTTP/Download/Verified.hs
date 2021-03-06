{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE StandaloneDeriving    #-}
module Network.HTTP.Download.Verified
  ( verifiedDownload
  , DownloadRequest(..)
  , HashCheck(..)
  , LengthCheck
  , VerifiedDownloadException(..)
  ) where

import qualified Data.List as List
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Char8 as BC
import qualified Data.Conduit.Binary as CB
import qualified Data.Conduit.List as CL
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text

import Control.Monad
import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.Reader
import Control.Applicative
import Crypto.Hash
import Crypto.Hash.Conduit (sinkHash)
import Data.ByteString (ByteString)
import Data.Conduit
import Data.Conduit.Binary (sourceHandle, sinkHandle)
import Data.Foldable (traverse_)
import Data.Monoid
import Data.Typeable (Typeable)
import Network.HTTP.Client.Conduit
import Network.HTTP.Types.Header (hContentLength, hContentMD5)
import Path
import Prelude -- Fix AMP warning
import System.FilePath((<.>))
import System.Directory
import System.IO

-- | A request together with some checks to perform.
data DownloadRequest = DownloadRequest
    { drRequest :: Request
    , drHashChecks :: [HashCheck]
    , drLengthCheck :: Maybe LengthCheck
    }
  deriving Show

data HashCheck = forall a. (Show a, HashAlgorithm a) => HashCheck
  { hashCheckAlgorithm :: a
  , hashCheckHexDigest :: String
  }
deriving instance Show HashCheck

type LengthCheck = Int

-- | An exception regarding verification of a download.
data VerifiedDownloadException
    = WrongContentLength
          Int -- expected
          ByteString -- actual (as listed in the header)
    | WrongStreamLength
          Int -- expected
          Int -- actual
    | WrongDigest
          String -- algorithm
          String -- expected
          String -- actual
  deriving (Show, Typeable)
instance Exception VerifiedDownloadException

data VerifyFileException
    = WrongFileSize
          Int -- expected
          Integer -- actual (as listed by hFileSize)
  deriving (Show, Typeable)
instance Exception VerifyFileException

-- | Make sure that the hash digest for a finite stream of bytes
-- is as expected.
--
-- Throws WrongDigest (VerifiedDownloadException)
sinkCheckHash :: MonadThrow m
    => HashCheck
    -> Consumer ByteString m ()
sinkCheckHash HashCheck{..} = do
    digest <- sinkHashUsing hashCheckAlgorithm
    let actualDigestString = show digest
    when (actualDigestString /= hashCheckHexDigest) $
        throwM $ WrongDigest (show hashCheckAlgorithm) hashCheckHexDigest actualDigestString

assertLengthSink :: MonadThrow m
    => LengthCheck
    -> ZipSink ByteString m ()
assertLengthSink expectedStreamLength = ZipSink $ do
  Sum actualStreamLength <- CL.foldMap (Sum . ByteString.length)
  when (actualStreamLength /= expectedStreamLength) $
    throwM $ WrongStreamLength expectedStreamLength actualStreamLength

-- | A more explicitly type-guided sinkHash.
sinkHashUsing :: (Monad m, HashAlgorithm a) => a -> Consumer ByteString m (Digest a)
sinkHashUsing _ = sinkHash

-- | Turns a list of hash checks into a ZipSink that checks all of them.
hashChecksToZipSink :: MonadThrow m => [HashCheck] -> ZipSink ByteString m ()
hashChecksToZipSink = traverse_ (ZipSink . sinkCheckHash)

-- | Copied and extended version of Network.HTTP.Download.download.
--
-- Has the following additional features:
-- * Verifies that response content-length header (if present)
--     matches expected length
-- * Limits the download to (close to) the expected # of bytes
-- * Verifies that the expected # bytes were downloaded (not too few)
-- * Verifies md5 if response includes content-md5 header
-- * Verifies the expected hashes
--
-- Throws VerifiedDownloadException, and whatever else "download" throws.
verifiedDownload :: (MonadReader env m, HasHttpManager env, MonadIO m)
         => DownloadRequest
         -> Path Abs File -- ^ destination
         -> Sink ByteString (ReaderT env IO) () -- ^ custom hook to observe progress
         -> m Bool -- ^ Whether a download was performed
verifiedDownload DownloadRequest{..} destpath progressSink = do
    let req = drRequest
    env <- ask
    liftIO $ whenM' getShouldDownload $ do
        createDirectoryIfMissing True dir
        withBinaryFile fptmp WriteMode $ \h ->
            flip runReaderT env $
                withResponse req (go h)
        renameFile fptmp fp
  where
    whenM' mp m = do
        p <- mp
        if p then m >> return True else return False

    fp = toFilePath destpath
    fptmp = fp <.> "tmp"
    dir = toFilePath $ parent destpath

    getShouldDownload = do
        fileExists <- doesFileExist fp
        if fileExists
            -- only download if file does not match expectations
            then not <$> fileMatchesExpectations
            -- or if it doesn't exist yet
            else return True

    -- precondition: file exists
    -- TODO: add logging
    fileMatchesExpectations =
        (checkExpectations >> return True)
          `catch` \(_ :: VerifyFileException) -> return False
          `catch` \(_ :: VerifiedDownloadException) -> return False

    whenJust :: Monad m => Maybe a -> (a -> m ()) -> m ()
    whenJust (Just a) f = f a
    whenJust _ _ = return ()

    checkExpectations = bracket (openFile fp ReadMode) hClose $ \h -> do
        whenJust drLengthCheck $ checkFileSizeExpectations h
        sourceHandle h $$ getZipSink (hashChecksToZipSink drHashChecks)

    -- doesn't move the handle
    checkFileSizeExpectations h expectedFileSize = do
        fileSizeInteger <- hFileSize h
        when (fileSizeInteger > toInteger (maxBound :: Int)) $
            throwM $ WrongFileSize expectedFileSize fileSizeInteger
        let fileSize = fromInteger fileSizeInteger
        when (fileSize /= expectedFileSize) $
            throwM $ WrongFileSize expectedFileSize fileSizeInteger

    checkContentLengthHeader headers expectedContentLength = do
        case List.lookup hContentLength headers of
            Just lengthBS -> do
              let lengthText = Text.strip $ Text.decodeUtf8 lengthBS
                  lengthStr = Text.unpack lengthText
              when (lengthStr /= show expectedContentLength) $
                throwM $ WrongContentLength expectedContentLength lengthBS
            _ -> return ()

    go h res = do
        let headers = responseHeaders res
        whenJust drLengthCheck $ checkContentLengthHeader headers
        let hashChecks = (case List.lookup hContentMD5 headers of
                Just md5BS ->
                    let md5ExpectedHexDigest =  BC.unpack (B64.decodeLenient md5BS)
                    in  [ HashCheck
                              { hashCheckAlgorithm = MD5
                              , hashCheckHexDigest = md5ExpectedHexDigest
                              }
                        ]
                Nothing -> []
                ) ++ drHashChecks

        responseBody res
            $= maybe (awaitForever yield) CB.isolate drLengthCheck
            $$ getZipSink
                ( hashChecksToZipSink hashChecks
                  *> maybe (pure ()) assertLengthSink drLengthCheck
                  *> ZipSink (sinkHandle h)
                  *> ZipSink progressSink)
