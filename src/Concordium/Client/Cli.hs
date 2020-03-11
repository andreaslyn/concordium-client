{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE RecordWildCards            #-}

module Concordium.Client.Cli where

import Concordium.Types
import Concordium.Types.Execution
import Concordium.Client.Types.Transaction
import qualified Concordium.ID.Types as IDTypes

import Control.Monad hiding (fail)
import Control.Monad.Fail
import qualified Data.HashMap.Strict as HM
import Data.Aeson as AE
import Data.Aeson.Types as AE
import Data.Char
import Data.List
import Data.Text (Text)
import Data.Text.Encoding
import Prelude hiding (fail, log)
import Text.Printf
import System.Exit (die, exitFailure)
import System.IO

data Level = Info | Warn | Err deriving (Eq)

-- Logs a list of sentences. The sentences are pretty printed (capital first letter and dot at the end),
-- so the input messages should only contain capital letters for names and have no dot suffix.
-- Sentences will be joined on the same line as long as the resulting line doesn't exceed 90 chars.
-- Depending on the log level, an appropriate prefix is added to the first line.
-- All lines will be indented such that they align with the first line
-- (i.e. as if they had all been prefixed).
log :: Level -> [String] -> IO ()
log lvl msgs =
  let ls = prettyLines 90 $ map prettyMsg msgs
      msg = foldl (\res l -> let p = if null res then prefix else indent in res ++ p ++ l ++ "\n") "" ls
  in logStr msg
  where prefix = case lvl of
                   Info -> ""
                   Warn-> "Warning: "
                   Err -> "Error: "
        indent = replicate (length prefix) ' '

logFatal :: [String] -> IO a
logFatal msgs = log Err msgs >> exitFailure

-- Joins sentences to a list of lines. Any given sentence is added to the current line if it
-- doesn't cause the total line length to exceed maxLineLen.
-- Impl note: The fold is "left" based for the length calculation to be correct.
prettyLines :: Int -> [String] -> [String]
prettyLines maxLineLen = reverse . foldl f []
  where f ls s = case ls of
                   [] -> [s]
                   (l:ls') -> if length l + length s + 1 > maxLineLen then
                                -- New string s doesn't fit on line; add as a new line.
                                s : ls
                              else
                                -- New string s fits on line; append it.
                                (l ++ " " ++ s) : ls'
prettyMsg :: String -> String
prettyMsg = \case
  "" -> ""
  (x:xs) -> (toUpper x : xs) ++ "."

logStr :: String -> IO ()
logStr = hPutStr stderr

logStrLn :: String -> IO ()
logStrLn = hPutStrLn stderr

data AccountInfoResult = AccountInfoResult
  { airAmount :: !Amount
  , airNonce :: !Nonce
  , airDelegation :: !(Maybe BakerId),
    -- TODO Change to ![IDTypes.CredentialDeploymentValues] once backend is updated.
    airCredentials :: ![(Int, IDTypes.CredentialDeploymentValues)] }
  deriving (Show)

instance AE.FromJSON AccountInfoResult where
  parseJSON = withObject "Account info" $ \v -> do
    airAmount <- v .: "accountAmount"
    airNonce <- v .: "accountNonce"
    airDelegation <- v .: "accountDelegation"
    airCredentials <- v .: "accountCredentials"
    return $ AccountInfoResult {..}

-- Hardcode network ID and hook.
defaultNetId :: Int
defaultNetId = 100

getArg :: String -> Maybe a -> IO a
getArg name input = case input of
  Nothing -> die $ name ++ " not provided"
  Just v -> return v

decodeJsonArg :: FromJSON a => String -> Maybe Text -> Maybe (Either String a)
decodeJsonArg key input = do
  v <- input
  Just $ case AE.eitherDecodeStrict $ encodeUtf8 v of
    Left err -> Left $ printf "%s: cannot parse '%s' as JSON: %s" key v err
    Right r -> Right r

decodeKeysArg :: Maybe Text -> Maybe (Either String KeyMap)
decodeKeysArg = decodeJsonArg "keys"

getAddressArg :: String -> Maybe Text -> IO IDTypes.AccountAddress
getAddressArg name input = do
  v <- getArg name input
  case IDTypes.addressFromText v of
    Left err -> die $ printf "%s: %s" name err
    Right a -> return a

data TransactionState = Received | Committed | Finalized | Absent deriving (Eq, Ord, Show)

type TransactionBlockResults = HM.HashMap BlockHash (Maybe TransactionSummary)

data TransactionStatusResult = TransactionStatusResult
  { tsrState :: !TransactionState
  , tsrResults :: !TransactionBlockResults } -- TODO Rename to "blocks".
  deriving (Eq, Show)

instance AE.FromJSON TransactionStatusResult where
  parseJSON Null = return TransactionStatusResult{tsrState = Absent, tsrResults = HM.empty}
  parseJSON v = flip (withObject "Transaction status") v $ \obj -> do
    tsrState <- (obj .: "status" :: Parser String) >>= \case
      "received" -> return Received
      "committed" -> return Committed
      "finalized" -> return Finalized
      s -> fail $ printf "invalid status '%s'" s
    tsrResults <- foldM (\hm (k, summary) -> do
                            case AE.fromJSON (String k) of
                              AE.Error _ -> return hm
                              AE.Success bh -> flip (HM.insert bh) hm <$> parseJSON summary
                        ) HM.empty (HM.toList obj)
    return $ TransactionStatusResult {..}

class (Monad m) => TransactionStatusQuery m where
  queryTransactionStatus :: TransactionHash -> m TransactionStatusResult
  wait :: Int -> m ()
