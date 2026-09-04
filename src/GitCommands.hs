-- Created by Nicholas Bisset 2025
--{-# LANGUAGE OverloadedStrings #-}

module GitCommands (
  delim,
  checkIfRepoExists,
  cloneRepo,
  checkIsGitDirectory,
  getBranches,
  getAllCommitsFrom,
  getContributorEmails,
  getCommitDetails,
  getCommitDiff,
  getRepoName
) where

import Command

delim :: String
delim  = "\\n|||END|||"

checkIfRepoExists :: String -> Maybe String -> Command
checkIfRepoExists url authToken = (authenticatedGitCommand authToken)
  { executable = "git"
  , arguments = arguments (authenticatedGitCommand authToken) ++ ["ls-remote", url]
  , onSuccess = \_ _ -> "Found Repo " ++ url
  , onFail = \_ e -> "Could not find Repo (" ++ url ++ "): " ++ e
  }

cloneRepo :: String -> FilePath -> Maybe String -> Command
cloneRepo url targetDirectory authToken = (authenticatedGitCommand authToken)
  { executable = "git"
  , arguments = arguments (authenticatedGitCommand authToken)
      ++ ["clone", "--bare", url, targetDirectory]
  , onSuccess = \_ _ -> url ++ " successfully cloned to " ++ targetDirectory
  , onFail = \c e -> "Error cloning repo:\nCommand:\n" ++ c ++ "\nError Message:\n" ++ e
  }

-- | Supply an optional token through a one-shot credential helper. The raw
-- token is held in the child process environment and never appears in the Git
-- URL or argument vector. Clearing inherited helpers prevents the service from
-- accidentally using machine-wide credentials for otherwise public requests.
authenticatedGitCommand :: Maybe String -> Command
authenticatedGitCommand authToken = doNotLogData
  { arguments = authenticationArguments authToken
  , env_vars = Just $ ("GIT_TERMINAL_PROMPT", "0") : tokenEnvironment authToken
  , env_clean = ["GIT_ASKPASS", "GCM_INTERACTIVE", "GIT_AUTH_TOKEN"]
  }
  where
    authenticationArguments Nothing =
      ["-c", "credential.helper=", "-c", "core.askPass=true"]
    authenticationArguments (Just _) =
      [ "-c", "credential.helper="
      , "-c", "credential.helper=" ++ credentialHelper
      , "-c", "credential.useHttpPath=true"
      , "-c", "core.askPass=true"
      ]
    tokenEnvironment Nothing = []
    tokenEnvironment (Just token) = [("GIT_AUTH_TOKEN", token)]
    credentialHelper =
      "!f() { if test \"$1\" = get; then "
        ++ "printf '%s\\n' 'username=x-access-token' \"password=$GIT_AUTH_TOKEN\"; "
        ++ "fi; }; f"

checkIsGitDirectory :: FilePath -> Command
checkIsGitDirectory dir = doNotLogData
  { executable = "git"
  , arguments = ["-C", dir, "rev-parse", "--git-dir"]
  }

getBranches :: Command
getBranches = doNotLogData
  { executable = "git"
  , arguments = ["--no-pager", "branch", "-a", "--format=%(refname:short)"]
  }

getAllCommitsFrom :: String -> Command
getAllCommitsFrom branch = doNotLogData
  { executable = "git"
  , arguments = ["--no-pager", "log", "--format=%H", "--end-of-options", branch, "--"]
  }

getContributorEmails :: String -> Command
getContributorEmails name = doNotLogData
  { executable = "git"
  , arguments = ["log", "--author=" ++ name, "--pretty=format:%ae", "--"]
  }

getCommitDetails :: String -> Command
getCommitDetails hash = doNotLogData
  { executable = "git"
  , arguments =
      [ "show"
      , "--pretty=format:%H" ++ delim ++ "%an" ++ delim ++ "%cI" ++ delim ++ "%s" ++ delim ++ "%b" ++ delim
      , "--name-status"
      , hash
      , "--"
      ]
  }

getCommitDiff :: String -> Command
getCommitDiff hash = doNotLogData
  { executable = "git"
  , arguments = ["--no-pager", "diff-tree", "-p", hash, "--"]
  }

getRepoName :: Command
getRepoName = doNotLogData
  { executable = "git"
  , arguments = ["remote", "get-url", "origin"]
  }
