-- Created by Nicholas Bisset 2025
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use join" #-}
{-# LANGUAGE LambdaCase #-}
{-# HLINT ignore "Use tuple-section" #-}

module Process (
    fetchDataFrom,
    parsingPool,
    commandPool
) where

import Control.Concurrent.STM
import Control.Exception (
    AsyncException,
    SomeException,
    bracket,
    catch,
    displayException,
    evaluate,
    fromException,
    mask,
    onException,
    throwIO)
import Control.DeepSeq (force)
import Data.List (sortBy, isPrefixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as Map
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import System.Directory (
    getTemporaryDirectory,
    createDirectoryIfMissing)
import Control.Concurrent (
    MVar,
    getNumCapabilities,
    modifyMVar,
    modifyMVar_,
    newMVar,
    withMVar,
    )
import Control.Monad (void)

import Types
import Threading
import Command
import GitCommands
import Parsing
import Security
  ( RepositoryTarget(..)
  , configuredAllowedHosts
  , repositoryAccessPath
  , validateAuthToken
  , validateRepositoryUrl
  )

-- Create global thread pools
-- Initialize RTS and return pools
{-# NOINLINE globalPools #-}
globalPools :: (WorkerPool, WorkerPool)
globalPools = unsafePerformIO $ do
    cap <- getNumCapabilities
    -- Create the pools
    parsing <- createThreadPool cap "Parsing Pool"
    commands <- createThreadPool (cap * 4) "Command Pool"
    pure (parsing, commands)

-- Expose them as pure values
{-# NOINLINE parsingPool #-}
parsingPool :: WorkerPool
parsingPool = fst globalPools

{-# NOINLINE commandPool #-}
commandPool :: WorkerPool
commandPool = snd globalPools

-- Concurrent requests for the same cleaned repository URL share one complete
-- fetch. This sits above the directory locks, which remain responsible for
-- protecting future operations that use the same on-disk directory.
{-# NOINLINE repositoryRequestBatch #-}
repositoryRequestBatch :: AwaitBatch String (Either String RepositoryData)
repositoryRequestBatch = unsafePerformIO newAwaitBatch

-- global Disk resource registeries
type RefCountMap = Map.Map FilePath Int
type SemaphoreMap = Map.Map FilePath (MVar (), Int)

-- Global registry of per-directory locks
{-# NOINLINE directoryRefCount #-}
directoryRefCount :: MVar RefCountMap
directoryRefCount = unsafePerformIO (newMVar Map.empty)

-- Global registry of per-directory semaphores to store whether it exists or not
{-# NOINLINE directorySemaphores #-}
directorySemaphores :: MVar SemaphoreMap
directorySemaphores = unsafePerformIO (newMVar Map.empty)

-- | Register a user of a directory semaphore, creating one if necessary.
-- Counting holders and waiters prevents lock replacement while an old
-- semaphore is still reachable.
acquireDirSemaphore :: FilePath -> IO (MVar ())
acquireDirSemaphore path = modifyMVar directorySemaphores $ \semMap ->
    case Map.lookup path semMap of
        Just (sem, users) ->
            pure (Map.insert path (sem, users + 1) semMap, sem)
        Nothing -> do
            sem <- newMVar ()
            pure (Map.insert path (sem, 1) semMap, sem)

releaseDirSemaphore :: FilePath -> MVar () -> IO ()
releaseDirSemaphore path _ = modifyMVar_ directorySemaphores $ \semMap ->
    pure $ case Map.lookup path semMap of
        Just (_, 1) -> Map.delete path semMap
        Just (sem, users) -> Map.insert path (sem, users - 1) semMap
        Nothing -> semMap

-- | Acquire the per-directory lock and run an action.
withDirectoryLock :: FilePath -> IO a -> IO a
withDirectoryLock path action =
    bracket (acquireDirSemaphore path) (releaseDirSemaphore path) $ \sem ->
        withMVar sem $ const action

-- | Create a directory if needed and run a task, tracking refcount.
createDirectory :: FilePath -> (FilePath -> IO a) -> IO (Maybe a)
createDirectory path task = do
    -- Acquire the per-directory lock to prevent concurrent initialization
    withDirectoryLock path $ do
        mEntry <- modifyMVar directoryRefCount $ \refMap ->
            case Map.lookup path refMap of
                Nothing -> pure (refMap, True)                         -- directory not yet created
                Just n  -> pure (Map.insert path (n + 1) refMap, False) -- increment counter

        if mEntry then do
            mask $ \restore -> do
                let initialize = do
                        createDirectoryIfMissing True path
                        task path
                    cleanup = void $ deleteDirectoryIfExists path (pure ())
                taskResult <- restore initialize `onException` cleanup
                -- Publish initialization while masked so cancellation cannot
                -- leave initialized disk state without its refcount.
                modifyMVar_ directoryRefCount $
                    pure . Map.insert path 1
                pure (Just taskResult)
        else pure Nothing

-- | Delete a directory safely (only one thread per dir at a time)
deleteDirectory :: FilePath -> IO () -> IO Bool
deleteDirectory path callback =
    -- Acquire the directory lock first to avoid circular locking
    withDirectoryLock path $ do
        -- Now safely modify the refcount
        mDelete <- modifyMVar directoryRefCount $ \refMap ->
            case Map.lookup path refMap of
                Nothing -> pure (refMap, False)                       -- nothing to do
                Just 1  -> pure (Map.delete path refMap, True)        -- remove entry 
                Just n  -> if n > 0
                    then pure (Map.insert path (n - 1) refMap, False) -- decrement entry
                    else pure (refMap, False)                         -- do nothing if n <= 0

        -- Only delete if this call actually drops refcount to zero
        if mDelete
            then do
                _ <- deleteDirectoryIfExists path callback
                pure True
            else pure False

-- automatically execute shell scripts in the command pool whilst the command result is extracted and passed to the parsing pool
execAndParse :: TBQueue String -> FilePath -> Command -> (String -> ParseResult a) -> String -> IO a
execAndParse notifier cwd cmd parser msg = await (
        passThroughAsync commandPool parsingPool
        (executeCommand notifier cwd)
        (\commandResult -> do
            rawOutput <- parsed msg (successful commandResult)
            parsed msg (parser rawOutput))
        cmd
    )

execAndParseAll :: TBQueue String -> FilePath -> [Command] -> (String -> ParseResult a) -> String -> IO [a]
execAndParseAll notifier cwd cmds parser msg =
    passAllAsync commandPool parsingPool
    (executeCommand notifier cwd)
    (\commandResult -> do
        rawOutput <- parsed msg (successful commandResult)
        parsed msg (parser rawOutput))
    cmds

fetchDataFrom :: String -> Maybe String -> TBQueue String -> IO (Either String RepositoryData)
fetchDataFrom rawUrl rawAuthToken notifier = do
    allowedHosts <- configuredAllowedHosts
    case (validateRepositoryUrl allowedHosts rawUrl, validateAuthToken rawAuthToken) of
        (_, Left validationError) -> do
            emit notifier validationError
            pure (Left validationError)
        (Left validationError, _) -> do
            emit notifier validationError
            pure (Left validationError)
        (Right target, Right authToken) ->
            awaitBatched repositoryRequestBatch
                (repositoryAccessPath authToken target)
                (fetchDataFromUnbatched target authToken notifier)

fetchDataFromUnbatched :: RepositoryTarget -> Maybe String -> TBQueue String -> IO (Either String RepositoryData)
fetchDataFromUnbatched target authToken notifier = (do

        workingDir <- getTemporaryDirectory
        let cloneRoot = workingDir </> "cloned-repos"
            repoAbsPath = cloneRoot </> repositoryAccessPath authToken target
            url = repositoryUrl target

        createDirectoryIfMissing True cloneRoot
        emit notifier "Validating repo exists..."

        let execCmdInWorkingDir = execAndParse notifier workingDir
        _ <- execCmdInWorkingDir (checkIfRepoExists url authToken) parseRepoExists "Repo does not exist"

        emit notifier "Found the repo!"

        let initializeDirectory = createDirectory repoAbsPath $ \_ -> do
                emit notifier "Cloning repo..."
                commandResult <- executeCommandTimedOut 10 notifier cloneRoot (cloneRepo url repoAbsPath authToken)
                void $ parsed "Failed to clone the repo" $ successful commandResult

                ensureSuccess <- executeCommand notifier repoAbsPath (checkIsGitDirectory repoAbsPath)
                void $ parsed "Failed to initialise the filepath" $ successful ensureSuccess

            releaseDirectory _ =
                void $ deleteDirectory repoAbsPath (emit notifier "Cleaning Up Directory...")

            processing _ = do
                emit notifier "Getting repository data..."
                repoData <- formulateRepoData url repoAbsPath notifier
                evaluatedRepoData <- evaluate (force repoData)
                emit notifier "Data processed!"
                pure (Right evaluatedRepoData)

        bracket initializeDirectory releaseDirectory processing

    ) `catch` \(exception :: SomeException) ->
        case fromException exception :: Maybe AsyncException of
            Just _ -> throwIO exception
            Nothing -> do
                let exceptionText = displayException exception
                    errMsg = "Encountered error:\n" ++ exceptionText
                emit notifier errMsg
                safePrint errMsg
                pure (Left exceptionText)


-- | High-level function to orchestrate parsing, transforming, and assembling data
formulateRepoData :: String -> FilePath -> TBQueue String -> IO RepositoryData
formulateRepoData _url path notifier = do
    let execCmd = execAndParse notifier path
        execAll = execAndParseAll notifier path

    emit notifier "Searching for branch names..."
    collectedBranchNames <- execCmd getBranches parseRepoBranches "Failed to parse git branch names"
    let branchNameFilter = replace "remotes/" "" . replace "origin/" ""
        branchNames = unique collectedBranchNames
        filteredBranchNames = map branchNameFilter branchNames

    emit notifier "Searching for commit hashes..."
    allCommitHashesListOfList <- execAll (map getAllCommitsFrom branchNames) parseCommitHashes "Failed to parse commit hashes from branches"

    let allCommitHashes = unique $ concat allCommitHashesListOfList
        commitsFound = length allCommitHashes

    commitCounter <- newTVarIO (0 :: Int)
    emit notifier "Formulating all commit data..."
    allCommitData <- passAllAsync commandPool parsingPool
        (\(c1, c2) -> do
            let doCommitCommand = executeCommand notifier path
            r1 <- doCommitCommand c1
            r2 <- doCommitCommand c2
            pure (r1, r2)
        )
        (\(r1, r2) -> do
            let msg              = "Failed to formulate all commit data"
            raw1 <- parsed msg (successful r1)
            raw2 <- parsed msg (successful r2)
            ibCommitData <- parsed msg (parseCommitData raw1)
            metaFileInfoList <- mapM (parsed msg . parseFileDataFromCommit) (involvedFiles ibCommitData)
            metaFileDiffChanges <- parsed msg (parseFileDataFromDiff raw2)
            let commitFiles = mergeFileMetaData $ pairByFilePath metaFileInfoList metaFileDiffChanges

            count <- atomically $ do
                modifyTVar' commitCounter (+1)
                readTVar commitCounter
            emit notifier $ "Formulating all commit data (" ++ show count ++ "/" ++ show commitsFound ++ ")..."

            pure $ CommitData
                (ibCommitHash      ibCommitData ) --commitHash        
                (ibCommitTitle     ibCommitData ) --commitTitle     
                (ibContributorName ibCommitData ) --contributorName 
                (ibDescription     ibCommitData ) --description     
                (ibTimestamp       ibCommitData ) --timestamp       
                (commitFiles                    ) --fileData
            )
        (map (\h -> (getCommitDetails h, getCommitDiff h)) allCommitHashes)

    emit notifier "Formulating all contributors..."
    let uniqueNames = unique $ map contributorName allCommitData
    nameToEmails <- execAll (map getContributorEmails uniqueNames) parseContributorEmails "Failed to formulate contributor emails"

    let allContributors = zipWith ContributorData uniqueNames nameToEmails
        contributorMap = Map.fromList [(name c, c) | c <- allContributors]
        commitMap = Map.fromList [(commitHash c, c) | c <- allCommitData]

    emit notifier "Linking branches to their commits..."
    let branchToCommitsMap = Map.fromList $ zip filteredBranchNames allCommitHashesListOfList

    emit notifier "Formulating all branch data..."
    let timestampFor hash = maybe "" timestamp (Map.lookup hash commitMap)
        sortByTime h1 h2 = compare (timestampFor h2) (timestampFor h1)

    let branchData = map (\branch -> do
            let hashes = fromMaybe [] $ Map.lookup branch branchToCommitsMap
            let sortedHashes = sortBy sortByTime hashes
            BranchData branch sortedHashes
            ) filteredBranchNames

    emit notifier "Fetching repo name..."
    repoFetchedName <- execCmd getRepoName parseRepoName "Failed to retrieve repo name"

    pure $ RepositoryData
        repoFetchedName
        branchData
        commitMap
        contributorMap

unique :: Ord a => [a] -> [a]
unique = Map.keys . Map.fromList . flip zip (repeat ())

replace :: String -> String -> String -> String
replace old new str
    | old `isPrefixOf` str = new ++ drop (length old) str
replace _ _ [] = []
replace old new (x:xs) = x : replace old new xs
