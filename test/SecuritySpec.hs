module Main (main) where

import Control.Monad (unless)
import qualified Data.ByteString.Char8 as B8
import Data.List (isInfixOf)
import System.FilePath (splitDirectories)

import Command (Command(arguments, env_vars, executable))
import GitCommands
  ( checkIfRepoExists
  , cloneRepo
  , getAllCommitsFrom
  , getContributorEmails
  )
import Security
  ( RepositoryTarget(..)
  , apiKeyAuthorized
  , constantTimeEqual
  , repositoryAccessPath
  , validateAuthToken
  , validateRepositoryUrl
  )

assert :: String -> Bool -> IO ()
assert message condition = unless condition (ioError (userError message))

isRejected :: Either String a -> Bool
isRejected = either (const True) (const False)

main :: IO ()
main = do
  let allowed = ["github.com"]
      valid = validateRepositoryUrl allowed "https://github.com/Owner/Repo.git"
  assert "valid GitHub URL was rejected" $
    case valid of
      Right target -> repositoryUrl target == "https://github.com/Owner/Repo"
        && splitDirectories (repositoryPath target) == ["github.com", "Owner", "Repo"]
      Left _ -> False
  target <- case valid of
    Right value -> pure value
    Left err -> ioError (userError err)
  assert "embedded credentials were accepted" $
    isRejected (validateRepositoryUrl allowed "https://user:secret@github.com/Owner/Repo")
  assert "HTTP repository URL was accepted" $
    isRejected (validateRepositoryUrl allowed "http://github.com/Owner/Repo")
  assert "unlisted repository host was accepted" $
    isRejected (validateRepositoryUrl allowed "https://example.com/Owner/Repo")
  assert "query string was accepted" $
    isRejected (validateRepositoryUrl allowed "https://github.com/Owner/Repo?token=secret")
  assert "shell metacharacters were accepted in repository path" $
    isRejected (validateRepositoryUrl allowed "https://github.com/Owner/Repo%22%3Bwhoami")

  assert "missing repository token was rejected" $
    validateAuthToken Nothing == Right Nothing
  assert "empty repository token was accepted" $
    isRejected (validateAuthToken (Just ""))
  assert "repository token containing a newline was accepted" $
    isRejected (validateAuthToken (Just "secret\nusername=attacker"))

  let secret = "private-repository-secret"
      otherSecret = "another-private-repository-secret"
      publicPath = repositoryAccessPath Nothing target
      privatePath = repositoryAccessPath (Just secret) target
      otherPrivatePath = repositoryAccessPath (Just otherSecret) target
  assert "public repository path is not in the public namespace" $
    take 1 (splitDirectories publicPath) == ["public"]
  assert "authenticated repository reused the public path" $
    privatePath /= publicPath
  assert "different repository tokens reused the same path" $
    privatePath /= otherPrivatePath
  assert "repository token leaked into its clone path" $
    not (secret `isInfixOf` privatePath)
  assert "the same token did not produce a stable repository path" $
    privatePath == repositoryAccessPath (Just secret) target

  let privateProbe = checkIfRepoExists (repositoryUrl target) (Just secret)
      privateClone = cloneRepo (repositoryUrl target) "clone-target" (Just secret)
      publicProbe = checkIfRepoExists (repositoryUrl target) Nothing
  assert "repository token leaked into Git command arguments" $
    all (not . isInfixOf secret) (arguments privateProbe ++ arguments privateClone)
  assert "repository token was not passed through the child environment" $
    maybe False ((== Just secret) . lookup "GIT_AUTH_TOKEN") (env_vars privateProbe)
  assert "public Git request inherited a repository token" $
    maybe True ((== Nothing) . lookup "GIT_AUTH_TOKEN") (env_vars publicProbe)
  assert "private repository probe did not configure a credential helper" $
    any (isInfixOf "credential.helper=!") (arguments privateProbe)

  let maliciousName = "teacher\"; touch /tmp/pwned; \""
      authorCommand = getContributorEmails maliciousName
  assert "Git command does not use an argument vector" $
    executable authorCommand == "git"
      && ("--author=" ++ maliciousName) `elem` arguments authorCommand
  let branchArguments = arguments (getAllCommitsFrom "--exec-path=malicious")
  assert "repository-controlled revision was not separated from Git options" $
    take 4 branchArguments == ["--no-pager", "log", "--format=%H", "--end-of-options"]

  assert "equal API keys did not compare equal" $
    constantTimeEqual (B8.pack "same-key") (B8.pack "same-key")
  assert "different API keys compared equal" $
    not (constantTimeEqual (B8.pack "same-key") (B8.pack "other-key"))
  assert "missing API key was authorized" $
    not (apiKeyAuthorized (Just (B8.pack "expected")) Nothing)
  assert "wrong API key was authorized" $
    not (apiKeyAuthorized (Just (B8.pack "expected")) (Just (B8.pack "wrong")))

  putStrLn "security-tests: passed"
