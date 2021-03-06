{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ViewPatterns #-}

-- | All data types.

module Stack.Build.Types where

import Control.DeepSeq
import Control.Exception
import Data.Aeson
import Data.Binary (Binary(..))
import qualified Data.ByteString as S
import Data.Char (isSpace)
import Data.Data
import Data.Hashable
import Data.List (dropWhileEnd, nub, intercalate)
import Data.Map.Strict (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Monoid
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Distribution.Text (display)
import GHC.Generics
import Path (Path, Abs, File, Dir, mkRelDir, toFilePath, (</>))
import Prelude hiding (FilePath)
import Stack.Package
import Stack.Types
import System.Exit (ExitCode)
import System.FilePath (pathSeparator)

----------------------------------------------
-- Exceptions
data StackBuildException
  = Couldn'tFindPkgId PackageName
  | GHCVersionMismatch (Maybe Version) Version (Maybe (Path Abs File))
  -- ^ Path to the stack.yaml file
  | Couldn'tParseTargets [Text]
  | UnknownTargets [PackageName]
  | TestSuiteFailure PackageIdentifier (Map Text (Maybe ExitCode)) (Maybe (Path Abs File))
  | ConstructPlanExceptions [ConstructPlanException]
  | CabalExitedUnsuccessfully
        ExitCode
        PackageIdentifier
        (Path Abs File)  -- cabal Executable
        [String]         -- cabal arguments
        (Maybe (Path Abs File)) -- logfiles location
        S.ByteString     -- log contents
  | ExecutionFailure [SomeException]
  deriving Typeable

instance Show StackBuildException where
    show (Couldn'tFindPkgId name) =
              ("After installing " <> packageNameString name <>
               ", the package id couldn't be found " <> "(via ghc-pkg describe " <>
               packageNameString name <> "). This shouldn't happen, " <>
               "please report as a bug")
    show (GHCVersionMismatch mactual expected mstack) = concat
                [ case mactual of
                    Nothing -> "No GHC found, expected version "
                    Just actual ->
                        "GHC version mismatched, found " ++
                        versionString actual ++
                        ", but expected version "
                , versionString expected
                , " (based on "
                , case mstack of
                    Nothing -> "command line arguments"
                    Just stack -> "resolver setting in " ++ toFilePath stack
                , "). Try running stack setup"
                ]
    show (Couldn'tParseTargets targets) = unlines
                $ "The following targets could not be parsed as package names or directories:"
                : map T.unpack targets
    show (UnknownTargets targets) =
                "The following target packages were not found: " ++
                intercalate ", " (map packageNameString targets)
    show (TestSuiteFailure ident codes mlogFile) = unlines $ concat
        [ ["Test suite failure for package " ++ packageIdentifierString ident]
        , flip map (Map.toList codes) $ \(name, mcode) -> concat
            [ "    "
            , T.unpack name
            , ": "
            , case mcode of
                Nothing -> " executable not found"
                Just ec -> " exited with: " ++ show ec
            ]
        , return $ case mlogFile of
            Nothing -> "Logs printed to console"
            -- TODO Should we load up the full error output and print it here?
            Just logFile -> "Full log available at " ++ toFilePath logFile
        ]
    show (ConstructPlanExceptions exceptions) =
        "While constructing the BuildPlan the following exceptions were encountered:" ++
        appendExceptions (removeDuplicates exceptions)
         where
             appendExceptions = foldr (\e -> (++) ("\n\n--" ++ show e)) ""
             removeDuplicates = nub
     -- Supressing duplicate output
    show (CabalExitedUnsuccessfully exitCode taskProvides' execName fullArgs logFiles bs) =
        let fullCmd = (dropQuotes (show execName) ++ " " ++ (unwords fullArgs))
            logLocations = maybe "" (\fp -> "\n    Logs have been written to: " ++ show fp) logFiles
        in "\n--  While building package " ++ dropQuotes (show taskProvides') ++ " using:\n" ++
           "      " ++ fullCmd ++ "\n" ++
           "    Process exited with code: " ++ show exitCode ++
           logLocations ++
           (if S.null bs
                then ""
                else "\n\n" ++ doubleIndent (T.unpack $ decodeUtf8With lenientDecode bs))
         where
          -- appendLines = foldr (\pName-> (++) ("\n" ++ show pName)) ""
          indent = dropWhileEnd isSpace . unlines . fmap (\line -> "  " ++ line) . lines
          dropQuotes = filter ('\"' /=)
          doubleIndent = indent . indent
    show (ExecutionFailure es) = intercalate "\n\n" $ map show es

instance Exception StackBuildException

data ConstructPlanException
    = DependencyCycleDetected [PackageName]
    | DependencyPlanFailures PackageName (Map PackageName (VersionRange, BadDependency))
    | UnknownPackage PackageName -- TODO perhaps this constructor will be removed, and BadDependency will handle it all
    -- ^ Recommend adding to extra-deps, give a helpful version number?
    deriving (Typeable, Eq)

-- | Reason why a dependency was not used
data BadDependency
    = NotInBuildPlan -- TODO add recommended version so it can be added to extra-deps
    | Couldn'tResolveItsDependencies
    | DependencyMismatch Version
    deriving (Typeable, Eq)

instance Show ConstructPlanException where
  show e =
    let details = case e of
         (DependencyCycleDetected pNames) ->
           "While checking call stack,\n" ++
           "  dependency cycle detected in packages:" ++ indent (appendLines pNames)
         (DependencyPlanFailures pName (Map.toList -> pDeps)) ->
           "Failure when adding dependencies:" ++ doubleIndent (appendDeps pDeps) ++ "\n" ++
           "  needed for package: " ++ show pName
         (UnknownPackage pName) ->
             "While attempting to add dependency,\n" ++
             "  Could not find package " ++ show pName  ++ " in known packages"
    in indent details
     where
      appendLines = foldr (\pName-> (++) ("\n" ++ show pName)) ""
      indent = dropWhileEnd isSpace . unlines . fmap (\line -> "  " ++ line) . lines
      doubleIndent = indent . indent
      appendDeps = foldr (\dep-> (++) ("\n" ++ showDep dep)) ""
      showDep (name, (range, badDep)) = concat
        [ show name
        , ": needed ("
        , display range
        , "), but "
        , case badDep of
            NotInBuildPlan -> "not present in build plan"
            Couldn'tResolveItsDependencies -> "couldn't resolve its dependencies"
            DependencyMismatch version -> versionString version ++ " found"
        ]
         {- TODO Perhaps change the showDep function to look more like this:
          dropQuotes = filter ((/=) '\"')
         (VersionOutsideRange pName pIdentifier versionRange) ->
             "Exception: Stack.Build.VersionOutsideRange\n" ++
             "  While adding dependency for package " ++ show pName ++ ",\n" ++
             "  " ++ dropQuotes (show pIdentifier) ++ " was found to be outside its allowed version range.\n" ++
             "  Allowed version range is " ++ display versionRange ++ ",\n" ++
             "  should you correct the version range for " ++ dropQuotes (show pIdentifier) ++ ", found in [extra-deps] in the project's stack.yaml?"
             -}


----------------------------------------------

-- | Configuration for building.
data BuildOpts =
  BuildOpts {boptsTargets :: !(Either [Text] [PackageName])
             -- ^ Right value indicates that we're only installing
             -- dependencies, no local packages
            ,boptsLibProfile :: !Bool
            ,boptsExeProfile :: !Bool
            ,boptsEnableOptimizations :: !(Maybe Bool)
            ,boptsFinalAction :: !FinalAction
            ,boptsDryrun :: !Bool
            ,boptsGhcOptions :: ![Text]
            ,boptsFlags :: !(Map PackageName (Map FlagName Bool))
            }
  deriving (Show)

-- | Configuration for testing.
data TestConfig =
  TestConfig {tconfigTargets :: ![Text]
             }
  deriving (Show)

-- | Configuration for haddocking.
data HaddockConfig =
  HaddockConfig {hconfigTargets :: ![Text]
                }
  deriving (Show)

-- | Configuration for benchmarking.
data BenchmarkConfig =
  BenchmarkConfig {benchTargets :: ![Text]
                  ,benchInDocker :: !Bool}
  deriving (Show)

-- | Generated config for a package build.
data GenConfig =
  GenConfig {gconfigOptimize :: !Bool
            ,gconfigLibProfiling :: !Bool
            ,gconfigExeProfiling :: !Bool
            ,gconfigGhcOptions :: ![Text]
            ,gconfigFlags :: !(Map FlagName Bool)
            ,gconfigPkgId :: Maybe GhcPkgId}
  deriving (Generic,Show)

instance FromJSON GenConfig
instance ToJSON GenConfig

defaultGenConfig :: GenConfig
defaultGenConfig =
    GenConfig {gconfigOptimize = False
              ,gconfigLibProfiling = False
              ,gconfigExeProfiling = False
              ,gconfigGhcOptions = []
              ,gconfigFlags = mempty
              ,gconfigPkgId = Nothing}

-- | Run a Setup.hs action after building a package, before installing.
data FinalAction
  = DoTests
  | DoBenchmarks
  | DoHaddock
  | DoNothing
  deriving (Eq,Bounded,Enum,Show)

data Dependencies =
  Dependencies {depsLibraries :: [PackageName]
               ,depsTools :: [PackageName]}
  deriving (Show,Typeable,Data)

-- | Used for mutex locking on the install step. Beats magic ().
data InstallLock = InstallLock

-- | Mutex for reading/writing .config files in dist/ of
-- packages. Shake works in parallel, without this there are race
-- conditions.
data ConfigLock = ConfigLock

-- | Package dependency oracle.
newtype PkgDepsOracle =
    PkgDeps PackageName
    deriving (Show,Typeable,Eq,Hashable,Binary,NFData)

-- | A location to install a package into, either snapshot or local
data Location = Snap | Local
    deriving (Show, Eq)

-- | Datatype which tells how which version of a package to install and where
-- to install it into
class PackageInstallInfo a where
    piiVersion :: a -> Version
    piiLocation :: a -> Location

-- | Information on a locally available package of source code
data LocalPackage = LocalPackage
    { lpPackage        :: !Package         -- ^ The @Package@ info itself, after resolution with package flags
    , lpWanted         :: !Bool            -- ^ Is this package a \"wanted\" target based on command line input
    , lpDir            :: !(Path Abs Dir)  -- ^ Directory of the package.
    , lpCabalFile      :: !(Path Abs File) -- ^ The .cabal file
    , lpLastConfigOpts :: !(Maybe ConfigCache)  -- ^ configure options used during last Setup.hs configure, if available
    , lpDirtyFiles     :: !Bool            -- ^ are there files that have changed since the last build?
    }
    deriving Show

-- | Stored on disk to know whether the flags have changed or any
-- files have changed.
data ConfigCache = ConfigCache
    { configCacheOpts :: ![S.ByteString]
      -- ^ All options used for this package.
    , configCacheDeps :: !(Set GhcPkgId)
      -- ^ The GhcPkgIds of all of the dependencies. Since Cabal doesn't take
      -- the complete GhcPkgId (only a PackageIdentifier) in the configure
      -- options, just using the previous value is insufficient to know if
      -- dependencies have changed.
    }
    deriving (Generic,Eq,Show)
instance Binary ConfigCache

-- | A task to perform when building
data Task = Task
    { taskProvides        :: !PackageIdentifier        -- ^ the package/version to be built
    , taskType            :: !TaskType                 -- ^ the task type, telling us how to build this
    , taskConfigOpts      :: !TaskConfigOpts
    , taskPresent         :: !(Set GhcPkgId)           -- ^ GhcPkgIds of already-installed dependencies
    }
    deriving Show

-- | Given the IDs of any missing packages, produce the configure options
data TaskConfigOpts = TaskConfigOpts
    { tcoMissing :: !(Set PackageIdentifier)
      -- ^ Dependencies for which we don't yet have an GhcPkgId
    , tcoOpts    :: !(Set GhcPkgId -> [Text])
      -- ^ Produce the list of options given the missing @GhcPkgId@s
    }
instance Show TaskConfigOpts where
    show (TaskConfigOpts missing f) = concat
        [ "Missing: "
        , show missing
        , ". Without those: "
        , show $ f Set.empty
        ]

-- | The type of a task, either building local code or something from the
-- package index (upstream)
data TaskType = TTLocal LocalPackage NeededSteps
              | TTUpstream Package Location
    deriving Show

-- | How many steps must be taken when building
data NeededSteps = AllSteps | SkipConfig | JustFinal
    deriving (Show, Eq)

-- | A complete plan of what needs to be built and how to do it
data Plan = Plan
    { planTasks :: !(Map PackageName Task)
    , planUnregisterLocal :: !(Set GhcPkgId)
    }

-- | Basic information used to calculate what the configure options are
data BaseConfigOpts = BaseConfigOpts
    { bcoSnapDB :: !(Path Abs Dir)
    , bcoLocalDB :: !(Path Abs Dir)
    , bcoSnapInstallRoot :: !(Path Abs Dir)
    , bcoLocalInstallRoot :: !(Path Abs Dir)
    , bcoBuildOpts :: !BuildOpts
    }

-- | Render a @BaseConfigOpts@ to an actual list of options
configureOpts :: BaseConfigOpts
              -> Set GhcPkgId -- ^ dependencies
              -> Bool -- ^ wanted?
              -> Location
              -> Map FlagName Bool
              -> [Text]
configureOpts bco deps wanted loc flags = map T.pack $ concat
    [ ["--user", "--package-db=clear", "--package-db=global"]
    , map (("--package-db=" ++) . toFilePath) $ case loc of
        Snap -> [bcoSnapDB bco]
        Local -> [bcoSnapDB bco, bcoLocalDB bco]
    , depOptions
    , [ "--libdir=" ++ toFilePathNoTrailingSlash (installRoot </> $(mkRelDir "lib"))
      , "--bindir=" ++ toFilePathNoTrailingSlash  (installRoot </> bindirSuffix)
      , "--datadir=" ++ toFilePathNoTrailingSlash  (installRoot </> $(mkRelDir "share"))
      , "--docdir=" ++ toFilePathNoTrailingSlash  (installRoot </> $(mkRelDir "doc"))
      ]
    , ["--enable-library-profiling" | boptsLibProfile bopts || boptsExeProfile bopts]
    , ["--enable-executable-profiling" | boptsExeProfile bopts]
    , ["--enable-tests" | wanted && boptsFinalAction bopts == DoTests]
    , ["--enable-benchmarks" | wanted && boptsFinalAction bopts == DoBenchmarks]
    , map (\(name,enabled) ->
                       "-f" <>
                       (if enabled
                           then ""
                           else "-") <>
                       flagNameString name)
                    (Map.toList flags)
    -- FIXME Chris: where does this come from now? , ["--ghc-options=-O2" | gconfigOptimize gconfig]
    , if wanted
        then concatMap (\x -> ["--ghc-options", T.unpack x]) (boptsGhcOptions bopts)
        else []
    ]
  where
    bopts = bcoBuildOpts bco
    toFilePathNoTrailingSlash =
        loop . toFilePath
      where
        loop [] = []
        loop [c]
            | c == pathSeparator = []
            | otherwise = [c]
        loop (c:cs) = c : loop cs
    installRoot =
        case loc of
            Snap -> bcoSnapInstallRoot bco
            Local -> bcoLocalInstallRoot bco

    depOptions = map toDepOption $ Set.toList deps

    {- TODO does this work with some versions of Cabal?
    toDepOption gid = T.pack $ concat
        [ "--dependency="
        , packageNameString $ packageIdentifierName $ ghcPkgIdPackageIdentifier gid
        , "="
        , ghcPkgIdString gid
        ]
    -}
    toDepOption gid = concat
        [ "--constraint="
        , packageNameString name
        , "=="
        , versionString version
        ]
      where
        PackageIdentifier name version = ghcPkgIdPackageIdentifier gid
