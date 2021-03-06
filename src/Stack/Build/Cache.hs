{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
-- | Cache information about previous builds
module Stack.Build.Cache
    ( tryGetBuildCache
    , tryGetConfigCache
    , getPackageFileModTimes
    , getInstalledExes
    , buildCacheTimes
    , tryGetFlagCache
    , deleteCaches
    , markExeInstalled
    , writeFlagCache
    , writeBuildCache
    , writeConfigCache
    ) where

import           Control.Exception.Enclosed (handleIO, tryIO)
import           Control.Monad              (liftM)
import           Control.Monad.Catch        (MonadCatch, MonadThrow, catch,
                                             throwM)
import           Control.Monad.IO.Class
import           Control.Monad.Logger       (MonadLogger)
import           Control.Monad.Reader       (MonadReader)
import           Data.Binary                (Binary)
import qualified Data.Binary                as Binary
import           Data.ByteString            (ByteString)
import qualified Data.ByteString            as S
import qualified Data.ByteString.Lazy       as L
import           Data.Map                   (Map)
import qualified Data.Map                   as Map
import           Data.Maybe                 (catMaybes, mapMaybe)
import           Data.Set                   (Set)
import qualified Data.Set                   as Set
import           Data.Text                  (Text)
import           Data.Text.Encoding         (encodeUtf8)
import           Data.Time                  (UTCTime (..), toModifiedJulianDay)
import           GHC.Generics               (Generic)
import           Path
import           Path.IO
import           Stack.Build.Types
import           Stack.Constants
import           Stack.GhcPkg               (getCabalPkgVer)
import           Stack.Package
import           Stack.Types
import           System.Directory           (createDirectoryIfMissing,
                                             getDirectoryContents,
                                             getModificationTime)
import           System.IO.Error            (isDoesNotExistError)

-- | Directory containing files to mark an executable as installed
exeInstalledDir :: (MonadReader env m, HasBuildConfig env, MonadThrow m)
                => Location -> m (Path Abs Dir)
exeInstalledDir Snap = (</> $(mkRelDir "installed-packages")) `liftM` installationRootDeps
exeInstalledDir Local = (</> $(mkRelDir "installed-packages")) `liftM` installationRootLocal

-- | Get all of the installed executables
getInstalledExes :: (MonadReader env m, HasBuildConfig env, MonadIO m, MonadThrow m)
                 => Location -> m [PackageIdentifier]
getInstalledExes loc = do
    dir <- exeInstalledDir loc
    files <- liftIO $ handleIO (const $ return []) $ getDirectoryContents $ toFilePath dir
    return $ mapMaybe parsePackageIdentifierFromString files

-- | Mark the given executable as installed
markExeInstalled :: (MonadReader env m, HasBuildConfig env, MonadIO m, MonadThrow m)
                 => Location -> PackageIdentifier -> m ()
markExeInstalled loc ident = do
    dir <- exeInstalledDir loc
    liftIO $ createDirectoryIfMissing True $ toFilePath dir
    ident' <- parseRelFile $ packageIdentifierString ident
    let fp = toFilePath $ dir </> ident'
    -- TODO consideration for the future: list all of the executables
    -- installed, and invalidate this file in getInstalledExes if they no
    -- longer exist
    liftIO $ writeFile fp "Installed"

-- | Stored on disk to know whether the flags have changed or any
-- files have changed.
data BuildCache = BuildCache
    { buildCacheTimes :: !(Map FilePath ModTime)
      -- ^ Modification times of files.
    }
    deriving (Generic,Eq)
instance Binary BuildCache

-- | Used for storage and comparison.
newtype ModTime = ModTime (Integer,Rational)
  deriving (Ord,Show,Generic,Eq)
instance Binary ModTime

-- | One-way conversion to serialized time.
modTime :: UTCTime -> ModTime
modTime x =
    ModTime
        ( toModifiedJulianDay
              (utctDay x)
        , toRational
              (utctDayTime x))

-- | Try to read the dirtiness cache for the given package directory.
tryGetBuildCache :: (MonadIO m, MonadReader env m, HasConfig env, MonadThrow m, MonadLogger m)
                 => Path Abs Dir -> m (Maybe BuildCache)
tryGetBuildCache = tryGetCache buildCacheFile

-- | Try to read the dirtiness cache for the given package directory.
tryGetConfigCache :: (MonadIO m, MonadReader env m, HasConfig env, MonadThrow m, MonadLogger m)
                  => Path Abs Dir -> m (Maybe ConfigCache)
tryGetConfigCache = tryGetCache configCacheFile

-- | Try to load a cache.
tryGetCache :: (MonadIO m, Binary a, MonadReader env m, HasConfig env, MonadThrow m, MonadLogger m)
            => (PackageIdentifier -> Path Abs Dir -> m (Path Abs File))
            -> Path Abs Dir
            -> m (Maybe a)
tryGetCache get' dir = do
    menv <- getMinimalEnvOverride
    cabalPkgVer <- getCabalPkgVer menv
    fp <- get' cabalPkgVer dir
    liftIO
        (catch
             (fmap (decodeMaybe . L.fromStrict) (S.readFile (toFilePath fp)))
             (\e -> if isDoesNotExistError e
                       then return Nothing
                       else throwM e))
  where decodeMaybe =
            either (const Nothing) (Just . thd) . Binary.decodeOrFail
          where thd (_,_,x) = x

-- | Write the dirtiness cache for this package's files.
writeBuildCache :: (MonadIO m, MonadReader env m, HasConfig env, MonadThrow m, MonadLogger m)
                => Path Abs Dir -> Map FilePath ModTime -> m ()
writeBuildCache dir times =
    writeCache
        dir
        buildCacheFile
        (BuildCache
         { buildCacheTimes = times
         })

-- | Write the dirtiness cache for this package's configuration.
writeConfigCache :: (MonadIO m, MonadReader env m, HasConfig env, MonadThrow m, MonadLogger m)
                => Path Abs Dir
                -> [Text]
                -> Set GhcPkgId -- ^ dependencies
                -> m ()
writeConfigCache dir opts deps =
    writeCache
        dir
        configCacheFile
        (ConfigCache
         { configCacheOpts = map encodeUtf8 opts
         , configCacheDeps = deps
         })

-- | Delete the caches for the project.
deleteCaches :: (MonadIO m, MonadReader env m, HasConfig env, MonadLogger m, MonadThrow m)
             => Path Abs Dir -> m ()
deleteCaches dir = do
    menv <- getMinimalEnvOverride
    cabalPkgVer <- getCabalPkgVer menv
    bfp <- buildCacheFile cabalPkgVer dir
    removeFileIfExists bfp
    cfp <- configCacheFile cabalPkgVer dir
    removeFileIfExists cfp

-- | Write to a cache.
writeCache :: (Binary a, MonadIO m, MonadLogger m, MonadThrow m, MonadReader env m, HasConfig env)
           => Path Abs Dir
           -> (PackageIdentifier -> Path Abs Dir -> m (Path Abs File))
           -> a
           -> m ()
writeCache dir get' content = do
    menv <- getMinimalEnvOverride
    cabalPkgVer <- getCabalPkgVer menv
    fp <- get' cabalPkgVer dir
    liftIO
        (L.writeFile
             (toFilePath fp)
             (Binary.encode content))

flagCacheFile :: (MonadIO m, MonadThrow m, MonadReader env m, HasBuildConfig env)
              => GhcPkgId
              -> m (Path Abs File)
flagCacheFile gid = do
    rel <- parseRelFile $ ghcPkgIdString gid
    dir <- flagCacheLocal
    return $ dir </> rel

-- | Loads the flag cache for the given installed extra-deps
tryGetFlagCache :: (MonadIO m, MonadThrow m, MonadReader env m, HasBuildConfig env)
                => GhcPkgId
                -> m (Maybe ConfigCache)
tryGetFlagCache gid = do
    file <- flagCacheFile gid
    eres <- liftIO $ tryIO $ Binary.decodeFileOrFail $ toFilePath file
    case eres of
        Right (Right x) -> return $ Just x
        _ -> return Nothing

writeFlagCache :: (MonadIO m, MonadReader env m, HasBuildConfig env, MonadThrow m)
               => GhcPkgId
               -> [ByteString]
               -> Set GhcPkgId
               -> m ()
writeFlagCache gid flags deps = do
    file <- flagCacheFile gid
    liftIO $ do
        createDirectoryIfMissing True $ toFilePath $ parent file
        Binary.encodeFile (toFilePath file) ConfigCache
            { configCacheOpts = flags
            , configCacheDeps = deps
            }

-- | Get the modified times of all known files in the package,
-- including the package's cabal file itself.
getPackageFileModTimes :: (MonadIO m, MonadLogger m, MonadThrow m, MonadCatch m)
                       => Package
                       -> Path Abs File -- ^ cabal file
                       -> m (Map FilePath ModTime)
getPackageFileModTimes pkg cabalfp = do
    files <- getPackageFiles (packageFiles pkg) cabalfp
    liftM (Map.fromList . catMaybes)
        $ mapM getModTimeMaybe
        $ Set.toList files
  where
    getModTimeMaybe fp =
        liftIO
            (catch
                 (liftM
                      (Just . (toFilePath fp,) . modTime)
                      (getModificationTime (toFilePath fp)))
                 (\e ->
                       if isDoesNotExistError e
                           then return Nothing
                           else throwM e))
