module Concordium.Client.Cli where

import qualified Concordium.Crypto.BlockSignature as BlockSig
import qualified Concordium.Crypto.BlsSignature as Bls
import qualified Concordium.Crypto.VRF as VRF
import qualified Concordium.ID.Types as IDTypes
import Concordium.Types

import Concordium.Client.Parse
import Concordium.Client.Types.TransactionStatus
import Concordium.Client.Types.Account
import Concordium.Client.Encryption

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Except
import Control.Exception

import Data.Aeson as AE
import qualified Data.Char as C
import Data.List
import qualified Data.HashMap.Strict as Map
import Data.Maybe
import Data.Text(Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Data.Time
import Data.Time.Clock.POSIX
import Data.Word
import Prelude hiding (fail, log)
import Text.PrettyPrint
import Text.Printf
import System.Console.ANSI
import System.Exit (exitFailure, exitSuccess)
import System.IO

data Level = Info | Warn | Err deriving (Eq)

-- |Log a list of sentences. The sentences are pretty printed (capital first letter and dot at the end),
-- so the input messages should only contain capital letters for names and have no dot suffix.
-- Sentences will be joined on the same line as long as the resulting line doesn't exceed 90 chars.
-- Depending on the log level, an appropriate prefix is added to the first line.
-- All lines will be indented such that they align with the first line
-- (i.e. as if they had all been prefixed).
log :: MonadIO m => Level -> Maybe Color -> [String] -> m ()
log lvl color msgs = do
  let doc = prefix <+> fsep (expandLines $ map (prettyMsg ".") msgs)
      out = logStrLn $ renderStyle s doc
  case color of
    Nothing -> out
    Just c -> do
      liftIO $ setSGR [SetColor Foreground Vivid c]
      out
      liftIO $ setSGR [Reset]
  where
    s = Style { mode = PageMode, lineLength = 90, ribbonsPerLine = 1.0 }
    prefix = case lvl of
               Info -> empty
               Warn-> text "Warning:"
               Err -> text "Error:"

logSuccess :: MonadIO m => [String] -> m ()
logSuccess = log Info $ Just Green

logInfo :: MonadIO m => [String] -> m ()
logInfo = log Info Nothing

logWarn :: MonadIO m => [String] -> m ()
logWarn = log Warn $ Just Yellow

logError :: MonadIO m => [String] -> m ()
logError = log Err $ Just Red

logFatal :: MonadIO m => [String] -> m a
logFatal msgs = logError msgs >> liftIO exitFailure

withLogFatal :: Either e' a -> (e' -> String) -> IO a
withLogFatal (Left x) f = logFatal [f x]
withLogFatal (Right x) _ = return x

withLogFatalIO :: IO (Either e' a) -> (e' -> String) -> IO a
withLogFatalIO action f = do
  v <- action
  v `withLogFatal` f

logExit :: MonadIO m => [String] -> m a
logExit msgs = logInfo msgs >> liftIO exitSuccess

-- |Expand each string into a document of the string's lines joined together using vcat.
expandLines :: [String] -> [Doc]
expandLines = map $ vcat . map text . lines

-- |Ensure that a string is printable as a sentence by converting the first letter to upper case
-- and, unless it already ends with "standard" punctuation, appending the provided punctionation.
prettyMsg :: String -> String -> String
prettyMsg punctuation = \case
  "" -> ""
  (x:xs) -> let s = if null xs || last xs `elem` p
                    then xs
                    else xs ++ punctuation
            in (C.toUpper x) : s
  where p = ".,:;?!{}" :: String

logStr :: MonadIO m => String -> m ()
logStr = liftIO . hPutStr stderr

logStrLn :: MonadIO m => String -> m ()
logStrLn = liftIO . hPutStrLn stderr

-- |Ask the user to "confirm" on stdin and return the result.
askConfirmation :: Maybe String -> IO Bool
askConfirmation prompt = do
  putStr $ prettyMsg " [yN]: " $ fromMaybe defaultPrompt prompt
  input <- T.getLine
  return $ T.strip (T.toLower input) == "y"
  where defaultPrompt = "confirm"

-- | Ask for a password on standard input not showing what is typed.
askPassword
  :: String -- ^ A text to display after which the password is typed (nothing is appended to this).
  -> IO Password
askPassword descr = do
  putStr descr
  -- Get the password from command line, not showing what is typed by temporarily disabling echo.
  passwordInput <- bracket_ (hSetEcho stdin False) (hSetEcho stdin True) T.getLine
  let password = T.encodeUtf8 passwordInput
  putStrLn ""
  return (Password password)

-- | Ask the user to create a new password, requiring to retype the password for confirmation.
createPasswordInteractive
  :: Maybe String -- ^ An optional description of the password, will be displayed after "... a new password to ".
  -> IO (Either String Password) -- ^ The password entered by the user or an error message on failure.
createPasswordInteractive descr = runExceptT $ do
  pwd <- liftIO $ askPassword $ "Please enter a new password" ++ maybe "" (" to " ++) descr ++ ": "
  pwd' <- liftIO $ askPassword "Please retype the password: "
  unless (pwd' == pwd) $ throwError "the passwords do not match"
  return pwd

-- | Decrypt the given encrypted account keys. For each key, this asks for the respective password
-- presenting the key index to the user.
decryptAccountKeyMapInteractive
  :: EncryptedAccountKeyMap
  -> Maybe String -- ^ Optional text describing the account of which to decrypt keys. Will be shown in the format
                  -- "Enter password for %s signing key"
  -> IO (Either String AccountKeyMap) -- ^ The decrypted 'AccountKeyMap' or an error message on failure.
decryptAccountKeyMapInteractive encryptedKeyMap accDescr = runExceptT $ do
  let accText = maybe " " (\s -> " " ++ s ++ " ") accDescr
  let queryText keyIndex =
        if Map.size encryptedKeyMap <= 1
        then "Enter password for" ++ accText ++ "signing key: "
        else case accDescr of
               Nothing -> "Enter password for signing key with index " ++ show keyIndex ++ ": "
               Just descr -> "Enter password for signing key of " ++ descr ++ " with index " ++ show keyIndex ++ ": "
  sequence $ Map.mapWithKey (\keyIndex eKp -> do
                                pwd <- liftIO $ askPassword $ queryText keyIndex
                                -- TODO When this fails, we get an IO exception instead of returning
                                -- the error string at the top-level.
                                decryptAccountKeyPair pwd keyIndex eKp
                            ) encryptedKeyMap



-- |Standardized method of exiting the command because the transaction is cancelled.
exitTransactionCancelled :: IO ()
exitTransactionCancelled = logExit ["transaction cancelled"]

getLocalTimeOfDay :: IO TimeOfDay
getLocalTimeOfDay = do
  tz <- getCurrentTimeZone
  localTimeOfDay . utcToLocalTime tz <$> getCurrentTime

getCurrentTimeUnix :: IO TransactionExpiryTime
getCurrentTimeUnix = TransactionExpiryTime . round <$> getPOSIXTime

timeFromTransactionExpiryTime :: TransactionExpiryTime -> UTCTime
timeFromTransactionExpiryTime = posixSecondsToUTCTime . fromIntegral . expiry

data AccountInfoResult = AccountInfoResult
  { airAmount :: !Amount
  , airNonce :: !Nonce
  , airDelegation :: !(Maybe BakerId),
    airCredentials :: ![IDTypes.CredentialDeploymentValues]
  , airInstances :: ![ContractAddress]}
  deriving (Show)

instance AE.FromJSON AccountInfoResult where
  parseJSON = withObject "Account info" $ \v -> do
    airAmount <- v .: "accountAmount"
    airNonce <- v .: "accountNonce"
    airDelegation <- v .: "accountDelegation"
    airCredentials <- v .: "accountCredentials"
    airInstances <- v .: "accountInstances"
    return $ AccountInfoResult {..}

data ConsensusStatusResult = ConsensusStatusResult
  { csrBestBlock :: BlockHash
  , csrGenesisBlock :: BlockHash
  , csrGenesisTime :: UTCTime
  , csrSlotDuration :: Word64
  , csrEpochDuration :: Word64
  , csrLastFinalizedBlock :: BlockHash
  , csrBestBlockHeight :: Word64
  , csrLastFinalizedBlockHeight :: Word64
  , csrBlocksReceivedCount :: Int
  , csrBlockLastReceivedTime :: Maybe UTCTime
  , csrBlockReceiveLatencyEMA :: Double
  , csrBlockReceiveLatencyEMSD :: Double
  , csrBlockReceivePeriodEMA :: Maybe Double
  , csrBlockReceivePeriodEMSD :: Maybe Double
  , csrBlocksVerifiedCount :: Int
  , csrBlockLastArrivedTime :: Maybe UTCTime
  , csrBlockArriveLatencyEMA :: Double
  , csrBlockArriveLatencyEMSD :: Double
  , csrBlockArrivePeriodEMA :: Maybe Double
  , csrBlockArrivePeriodEMSD :: Maybe Double
  , csrTransactionsPerBlockEMA :: Double
  , csrTransactionsPerBlockEMSD :: Double
  , csrFinalizationCount :: Int
  , csrLastFinalizedTime :: Maybe UTCTime
  , csrFinalizationPeriodEMA :: Maybe Double
  , csrFinalizationPeriodEMSD :: Maybe Double }

instance AE.FromJSON ConsensusStatusResult where
  parseJSON = withObject "Consensus state" $ \v -> do
    csrBestBlock <- v .: "bestBlock"
    csrGenesisBlock <- v .: "genesisBlock"
    csrGenesisTime <- v .: "genesisTime"
    csrSlotDuration <- v .: "slotDuration"
    csrEpochDuration <- v .: "epochDuration"
    csrLastFinalizedBlock <- v .: "lastFinalizedBlock"
    csrBestBlockHeight <- v .: "bestBlockHeight"
    csrLastFinalizedBlockHeight <- v .: "lastFinalizedBlockHeight"
    csrBlocksReceivedCount <- v .: "blocksReceivedCount"
    csrBlockLastReceivedTime <- v .: "blockLastReceivedTime"
    csrBlockReceiveLatencyEMA <- v .: "blockReceiveLatencyEMA"
    csrBlockReceiveLatencyEMSD <- v .: "blockReceiveLatencyEMSD"
    csrBlockReceivePeriodEMA <- v .: "blockReceivePeriodEMA"
    csrBlockReceivePeriodEMSD <- v .: "blockReceivePeriodEMSD"
    csrBlocksVerifiedCount <- v .: "blocksVerifiedCount"
    csrBlockLastArrivedTime <- v .: "blockLastArrivedTime"
    csrBlockArriveLatencyEMA <- v .: "blockArriveLatencyEMA"
    csrBlockArriveLatencyEMSD <- v .: "blockArriveLatencyEMSD"
    csrBlockArrivePeriodEMA <- v .: "blockArrivePeriodEMA"
    csrBlockArrivePeriodEMSD <- v .: "blockArrivePeriodEMSD"
    csrTransactionsPerBlockEMA <- v .: "transactionsPerBlockEMA"
    csrTransactionsPerBlockEMSD <- v .: "transactionsPerBlockEMSD"
    csrFinalizationCount <- v .: "finalizationCount"
    csrLastFinalizedTime <- v .: "lastFinalizedTime"
    csrFinalizationPeriodEMA <- v .: "finalizationPeriodEMA"
    csrFinalizationPeriodEMSD <- v .: "finalizationPeriodEMSD"
    return $ ConsensusStatusResult {..}

data BirkParametersResult = BirkParametersResult
  { bprElectionNonce :: LeadershipElectionNonce
  , bprElectionDifficulty :: ElectionDifficulty
  , bprBakers :: [BirkParametersBakerResult] }

instance AE.FromJSON BirkParametersResult where
  parseJSON = withObject "Birk parameters" $ \v -> do
    bprElectionNonce <- v .: "electionNonce"
    bprElectionDifficulty <- v .: "electionDifficulty"
    bprBakers <- v .: "bakers"
    return $ BirkParametersResult {..}

data BirkParametersBakerResult = BirkParametersBakerResult
  { bpbrId :: BakerId
  , bpbrLotteryPower :: ElectionDifficulty
  , bpbrAccount :: IDTypes.AccountAddress }

instance AE.FromJSON BirkParametersBakerResult where
  parseJSON = withObject "Baker" $ \v -> do
    bpbrId <- v .: "bakerId"
    bpbrLotteryPower <- v .: "bakerLotteryPower"
    bpbrAccount <- v .: "bakerAccount"
    return $ BirkParametersBakerResult {..}

data BlockInfoResult = BlockInfoResult
  { birBlockHash :: BlockHash
  , birBlockParent :: BlockHash
  , birBlockLastFinalized :: BlockHash
  , birBlockReceiveTime :: UTCTime
  , birBlockArriveTime :: UTCTime
  , birBlockSlot :: Word64
  , birBlockSlotTime :: UTCTime
  , birBlockBaker :: Maybe BakerId
  , birFinalized :: Bool
  , birTransactionCount :: Integer
  , birTransactionEnergyCost :: Energy
  , birTransactionsSize :: Integer }

instance AE.FromJSON BlockInfoResult where
  parseJSON = withObject "Block info" $ \v -> do
    birBlockHash <- v .: "blockHash"
    birBlockParent <- v .: "blockParent"
    birBlockLastFinalized <- v .: "blockLastFinalized"
    birBlockReceiveTime <- v .: "blockReceiveTime"
    birBlockArriveTime <- v .: "blockArriveTime"
    birBlockSlot <- v .: "blockSlot"
    birBlockSlotTime <- v .: "blockSlotTime"
    birBlockBaker <- v .: "blockBaker"
    birFinalized <- v .: "finalized"
    birTransactionCount <- v .: "transactionCount"
    birTransactionEnergyCost <- v .: "transactionEnergyCost"
    birTransactionsSize <- v .: "transactionsSize"
    return BlockInfoResult {..}

data NextAccountNonce = NextAccountNonce
  { nanNonce :: Nonce
  , nanAllFinal :: Bool }

instance AE.FromJSON NextAccountNonce where
  parseJSON = withObject "next nonce" $ \v -> do
    nanNonce <- v .: "nonce"
    nanAllFinal <- v .: "allFinal"
    return NextAccountNonce {..}

data BakerKeys =
  BakerKeys
  { bkSigSignKey :: BlockSig.SignKey
  , bkSigVerifyKey :: BlockSig.VerifyKey
  , bkAggrSignKey :: Bls.SecretKey
  , bkAggrVerifyKey :: Bls.PublicKey
  , bkElectionSignKey :: VRF.SecretKey
  , bkElectionVerifyKey :: VRF.PublicKey }

instance AE.FromJSON BakerKeys where
  parseJSON = withObject "Baker keys" $ \v -> do
    bkAggrSignKey <- v .: "aggregationSignKey"
    bkAggrVerifyKey <- v .: "aggregationVerifyKey"
    bkElectionSignKey <- v .: "electionPrivateKey"
    bkElectionVerifyKey <- v .: "electionVerifyKey"
    bkSigSignKey <- v .: "signatureSignKey"
    bkSigVerifyKey <- v .: "signatureVerifyKey"
    return BakerKeys {..}

instance AE.ToJSON BakerKeys where
  toJSON v = object [ "aggregationSignKey" .= bkAggrSignKey v
                    , "aggregationVerifyKey" .= bkAggrVerifyKey v
                    , "electionPrivateKey" .= bkElectionSignKey v
                    , "electionVerifyKey" .= bkElectionVerifyKey v
                    , "signatureSignKey" .= bkSigSignKey v
                    , "signatureVerifyKey" .= bkSigVerifyKey v ]

-- |Hardcoded network ID.
defaultNetId :: Int
defaultNetId = 100

-- |If the string starts with @ we assume the remaining characters are a file name
-- and we try to read the contents of that file.
decodeJsonArg :: FromJSON a => String -> Maybe (IO (Either String a))
decodeJsonArg s =
  Just $ do
    res <- case uncons s of
             Just ('@', rest) ->
               AE.eitherDecodeFileStrict rest
             _ -> return $ AE.eitherDecodeStrict $ T.encodeUtf8 $ T.pack s
    return $ case res of
               Left err -> Left $ printf "cannot parse '%s' as JSON: %s" s err
               Right r -> Right r

getExpiryArg :: String -> TransactionExpiryTime -> Maybe Text -> IO TransactionExpiryTime
getExpiryArg name now input =
  case input of
    Nothing -> return $ now + defaultExpiryDurationSecs
    Just v -> case parseExpiry now v of
                Left err -> logFatal [printf "invalid %s '%s': %s" name v err]
                Right e -> return e
  where defaultExpiryDurationSecs = 600 -- 10 mins

class (Monad m) => TransactionStatusQuery m where
  queryTransactionStatus :: TransactionHash -> m TransactionStatusResult
  wait :: Int -> m ()
