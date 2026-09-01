-- Created by Nicholas Bisset 2025
module Test where

import Control.Concurrent.Async (withAsync)
import Control.Concurrent.STM (atomically, newTBQueue, readTBQueue)
import Control.Monad (forever)
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as BL

import Process (fetchDataFrom)
import Threading (safePrint)
import Types (RepositoryData)

url1 :: String
url1 = "https://github.com/Densetsu152637/test_repo_for_3170"

url2 :: String
url2 = "https://github.com/Monash-FIT3170/2025W2-Commitment"

testApi :: IO ()
testApi = do
  result <- processUrl url2
  case result of
    Right repoData -> BL.putStrLn (encode repoData)
    Left failure -> safePrint failure

-- Process the URL and return repository data
processUrl :: String -> IO (Either String RepositoryData)
processUrl repoUrl = do
  notifier <- atomically $ newTBQueue 1000
  withAsync (forever $ atomically (readTBQueue notifier) >>= safePrint) $ \_ ->
    fetchDataFrom repoUrl notifier
