-- Created by Nicholas Bisset 2025
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Command (
  Command(..),
  CommandResult(..),
  getParsableStringFromCmd,
  defaultSuccess,
  defaultFail,
  defaultStdFail,
  logData,
  doNotLogData,
  executeCommand,
  executeCommandTimedOut,
  deleteDirectoryIfExists,
  copyDirectory
) where

import System.Exit (ExitCode(..))
import System.Environment (getEnvironment)
import System.Timeout (timeout)
import Control.Monad (when, forM_)
import Control.Concurrent.STM (TBQueue)
import Control.Exception (IOException, SomeException, catch, throwIO, try)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently)
import System.Directory
    ( copyFile,
      createDirectoryIfMissing,
      doesDirectoryExist,
      getDirectoryContents,
      removeDirectoryRecursive ) 
import System.Process
    ( proc,
      waitForProcess,
      withCreateProcess,
      CreateProcess(env, cwd, std_out, std_err),
      StdStream(CreatePipe) )
import System.FilePath ((</>))

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE

import Threading

data Command = Command
  { executable :: FilePath
  , arguments  :: [String]
  , env_vars   :: Maybe [(String, String)]
  , env_clean  :: [String]
  , onSuccess  :: String -> String -> String
  , onFail     :: String -> String -> String
  , onStdFail  :: String -> String -> String -> String
  , shouldLog  :: Bool
  }

data CommandResult = CommandResult
  { result   :: String
  , errorMsg :: Maybe String
  , stdError :: Maybe String
  } deriving (Show, Eq)

getParsableStringFromCmd :: CommandResult -> String
getParsableStringFromCmd (CommandResult _ (Just err) _) = err
getParsableStringFromCmd (CommandResult r _ (Just se))  = if null r then se else r
getParsableStringFromCmd (CommandResult r _ _)          = r

defaultSuccess :: String -> String -> String
defaultSuccess c output = "Command succeeded:\n" ++ c ++ "\nOutput:\n" ++ output

defaultFail :: String -> String -> String
defaultFail c e = "Command:\n" ++ c ++ "\nError:\n" ++ e

defaultStdFail :: String -> String -> String -> String
defaultStdFail c _ se = "Command:\n" ++ c ++ "\nError:\n" ++ se

logData :: Command
logData = Command "" [] Nothing [] defaultSuccess defaultFail defaultStdFail True

doNotLogData :: Command
doNotLogData = logData { shouldLog = False }

executeCommand :: TBQueue String -> FilePath -> Command -> IO CommandResult
executeCommand notifier filepath f = do
  valid <- doesDirectoryExist filepath
  if not valid
    then pure $ CommandResult "" (Just $ "Invalid filepath: " ++ filepath) Nothing
    else do
      let rawCmd = unwords (executable f : map show (arguments f))
      baseEnv <- getEnvironment
      let procEnv =
            case env_vars f of
              Nothing    -> Nothing
              Just extra -> do 
                let cleanedEnv = filter (\(k,_) -> k `notElem` env_clean f) baseEnv
                Just (cleanedEnv ++ extra)

      let processSpec = (proc (executable f) (arguments f))
            { cwd = Just filepath
            , std_out = CreatePipe
            , std_err = CreatePipe
            , env = procEnv
            }

      withCreateProcess processSpec $ \_ maybeOut maybeErr phandle ->
        case (maybeOut, maybeErr) of
          (Just hout, Just herr) -> do
            -- Drain both pipes concurrently. Reading either one first can
            -- deadlock when the child fills the other pipe's OS buffer.
            (rawOutBS, rawErrBS) <- concurrently
              (BS.hGetContents hout)
              (BS.hGetContents herr)

            let stdoutText = T.unpack (TE.decodeUtf8With TEE.lenientDecode rawOutBS)
                stderrText = T.unpack (TE.decodeUtf8With TEE.lenientDecode rawErrBS)

            exitCode <- waitForProcess phandle
            case exitCode of
              ExitFailure code -> do
                let commandError =
                      "Process exited with code "
                        ++ show code
                        ++ " from path: "
                        ++ filepath
                        ++ ":\n"
                        ++ onFail f rawCmd stderrText
                when (shouldLog f) $ emit notifier commandError
                pure $ CommandResult stdoutText (Just commandError)
                  (if null stderrText then Nothing else Just stderrText)

              ExitSuccess ->
                if null stderrText
                  then do
                    when (shouldLog f) $
                      emit notifier (onSuccess f rawCmd stdoutText)
                    pure $ CommandResult stdoutText Nothing Nothing
                  else do
                    when (shouldLog f) $ do
                      let stdErrMessage = "stderr:\n" ++ onStdFail f rawCmd stdoutText stderrText
                      emit notifier stdErrMessage
                    pure $ CommandResult stdoutText Nothing (Just stderrText)
          _ -> ioError $ userError "executeCommand: failed to create stdout/stderr pipes"

executeCommandTimedOut :: Int -> TBQueue String -> FilePath -> Command -> IO CommandResult
executeCommandTimedOut seconds notifier filepath cmd = do
  let micros = seconds * 1000000
  mres <- timeout micros (executeCommand notifier filepath cmd)
  case mres of
    Just res -> pure res
    Nothing  -> do
      let errMsg =
            "Process timed out after "
              ++ show micros ++ "μs "
            ++ "for command: " ++ unwords (executable cmd : map show (arguments cmd))
              ++ " in path: " ++ filepath
      when (shouldLog cmd) $
        emit notifier errMsg
      pure $ CommandResult "" (Just errMsg) Nothing

-- | Filesystem helpers
-- Deletes directory if it exists (raises errors when it fails)
deleteDirectoryIfExists :: FilePath -> IO () -> IO Bool
deleteDirectoryIfExists dir f = do
  exists <- doesDirectoryExist dir
  if exists 
    then do
      _ <- f
      retryDelete 3 Nothing
    else 
      pure False
  where
    retryDelete :: Int -> Maybe SomeException ->  IO Bool
    -- failed case
    retryDelete 0 previousError =
      throwIO $ userError $ "Failed to delete directory \"" ++ dir ++ "\": " ++ show previousError
    retryDelete n _ = do
      deletion <- try (removeDirectoryRecursive dir) :: IO (Either SomeException ())
      case deletion of
        Right _ -> pure True
        Left deletionError -> do
          threadDelay 1000000
          retryDelete (n - 1) $ Just deletionError

-- | Recursively copy one directory to another, including hidden files like `.git`.
copyDirectory :: FilePath -> FilePath -> IO ()
copyDirectory src dst = do
    createDirectoryIfMissing True dst
    contents <- getDirectoryContents src
    let properContents = filter (`notElem` [".", ".."]) contents
    forM_ properContents $ \name -> do
        let srcPath = src </> name
            dstPath = dst </> name
        isDir <- doesDirectoryExist srcPath
        if isDir
           then copyDirectory srcPath dstPath
           else copyFile srcPath dstPath `catch` \(copyError :: IOException) ->
                    safePrint $ "Failed to copy " ++ srcPath ++ " to " ++ dstPath ++ ": " ++ show copyError
    
