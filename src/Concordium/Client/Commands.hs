module Concordium.Client.Commands
  ( optsParser
  , backendParser
  , Verbose
  , Options(..)
  , Backend(..)
  , Cmd(..)
  , ConfigCmd(..)
  , TransactionCfg(..)
  , TransactionCmd(..)
  , AccountCmd(..)
  , ModuleCmd(..)
  , ContractCmd(..)
  , LegacyCmd(..)
  , ConsensusCmd(..)
  , BlockCmd(..)
  ) where

import Data.Text
import Data.Version (showVersion)
import Network.HTTP2.Client
import Options.Applicative
import Paths_simple_client (version)
import Concordium.Client.LegacyCommands
import Concordium.Types

type Verbose = Bool

data Options =
  Options
  { optsCmd :: Cmd
  , optsConfigDir :: Maybe FilePath
  , optsBackend :: Maybe Backend
  , optsVerbose :: Verbose }
  deriving (Show)

data Backend =
  GRPC
    { grpcHost   :: HostName
    , grpcPort   :: PortNumber
    , grpcTarget :: Maybe String }
  deriving (Show)

data Cmd
  = LegacyCmd
    { legacyCmd  :: LegacyCmd }
  | ConfigCmd
    { configCmd :: ConfigCmd }
  | TransactionCmd
    { transactionCmd :: TransactionCmd }
  | AccountCmd
    { accountCmd :: AccountCmd }
  | ModuleCmd
    { moduleCmd :: ModuleCmd }
  | ContractCmd
    { contractCmd :: ContractCmd }
  | ConsensusCmd
    { consensusCmd :: ConsensusCmd }
  | BlockCmd
    { blockCmd :: BlockCmd }
  deriving (Show)

data ConfigCmd
  = ConfigDump
  deriving (Show)

data TransactionCmd
  = TransactionSubmit
    { transactionSourceFile :: !FilePath }
  | TransactionStatus
    { transactionHash :: !Text }
  | TransactionSendGtu
    { transactionToAccount :: !Text
    , transactionAmount :: !Amount
    , transactionCfg :: !TransactionCfg }
  deriving (Show)

data AccountCmd
  = AccountShow
    { accountAddress :: !Text
    , accountBlockHash :: !(Maybe Text) }
  | AccountList
    { accountBlockHash :: !(Maybe Text) }
  deriving (Show)

data ModuleCmd
  = ModuleShow
    { ref :: !Text
    , moduleBlockHash :: !(Maybe Text) }
  | ModuleList
    { moduleBlockHash :: !(Maybe Text) }
  | ModuleDeploy
    { moduleName :: !Text
    , moduleTransactionCfg :: !TransactionCfg }
  deriving (Show)

data ContractCmd
  = ContractShow
    { contractAddress :: !Text
    , contractBlockHash :: !(Maybe Text) }
  | ContractList
    { contractBlockHash :: !(Maybe Text) }
  | ContractInit
    { contractModuleName :: !Text
    , contractName :: !Text
    , contractParameter :: !Text
    , contractTransactionCfg :: !TransactionCfg }
  deriving (Show)

data TransactionCfg =
  TransactionCfg
  { tcSender :: !(Maybe Text)
  , tcKeys :: !(Maybe Text)
  , tcNonce :: !(Maybe Nonce)
  , tcMaxEnergyAmount :: !(Maybe Energy)
  , tcExpiration :: !(Maybe TransactionExpiryTime) }
  deriving (Show)

data ConsensusCmd
  = ConsensusStatus
  | ConsensusShowParameters
    { cspBlockHash :: !(Maybe Text)
    , cspIncludeBakers :: !Bool }
  deriving (Show)

data BlockCmd
  = BlockShow
    { bsBlockHash :: !(Maybe Text) }
  deriving (Show)

optsParser :: ParserInfo Options
optsParser = info
               (helper <*> versionOption <*> programOptions)
               (fullDesc <> progDesc "Simple Client" <>
                header "simple-client - a small client to interact with the p2p-client")

versionOption :: Parser (a -> a)
versionOption =
  infoOption (showVersion version) (long "version" <> help "Show version")

backendParser :: Parser Backend
backendParser = GRPC <$> hostParser <*> portParser <*> targetParser

hostParser :: Parser HostName
hostParser =
  strOption
    (long "grpc-ip" <> metavar "GRPC-IP" <>
     help "IP address on which the gRPC server is listening")

portParser :: Parser PortNumber
portParser =
  option
    auto
    (long "grpc-port" <> metavar "GRPC-PORT" <>
     help "Port where the gRPC server is listening.")

targetParser :: Parser (Maybe String)
targetParser =
  optional $
  strOption
    (long "grpc-target" <> metavar "GRPC-TARGET" <>
     help "Target node name when using a proxy.")

transactionCfgParser :: Parser TransactionCfg
transactionCfgParser =
  TransactionCfg <$>
    optional (strOption (long "sender" <> metavar "SENDER" <> help "address of the transaction sender")) <*>
    optional (strOption (long "keys" <> metavar "KEYS" <> help "any number of sign/verify keys specified as JSON ({<key-idx>: {<sign-key>, <verify-key>})")) <*>
    optional (option auto (long "nonce" <> metavar "NONCE" <> help "transaction nonce")) <*>
    optional (option auto (long "energy" <> metavar "MAX-ENERGY" <> help "maximum allowed amount of energy to spend on transaction")) <*>
    optional (option auto (long "expiry" <> metavar "EXPIRY" <> help "expiration time of a transaction, specified as a UNIX epoch timestamp"))

programOptions :: Parser Options
programOptions = Options <$>
                   (hsubparser
                     (transactionCmds <>
                      accountCmds <>
                      moduleCmds <>
                      contractCmds <>
                      configCmds <>
                      consensusCmds <>
                      blockCmds
                     ) <|> (LegacyCmd <$> legacyProgramOptions)) <*>
                   (optional (strOption (long "config" <> metavar "DIR" <> help "Configuration directory path"))) <*>
                   (optional backendParser) <*>
                   (switch (long "verbose" <> short 'v' <> help "Make output verbose"))

transactionCmds :: Mod CommandFields Cmd
transactionCmds =
  command
    "transaction"
    (info
      (TransactionCmd <$>
        (hsubparser
          (transactionSubmitCmd <>
           transactionStatusCmd <>
           transactionSendGtuCmd)))
      (progDesc "commands for submitting and inspecting transactions"))

transactionSubmitCmd :: Mod CommandFields TransactionCmd
transactionSubmitCmd =
  command
    "submit"
    (info
      (TransactionSubmit <$>
        strArgument (metavar "FILE" <> help "File containing the transaction parameters in JSON format"))
      (progDesc "parse transaction and send it to the baker"))

transactionStatusCmd :: Mod CommandFields TransactionCmd
transactionStatusCmd =
  command
    "status"
    (info
      (TransactionStatus <$>
        strArgument (metavar "TX-HASH" <> help "hash of the transaction"))
      (progDesc "get status of a transaction"))

transactionSendGtuCmd :: Mod CommandFields TransactionCmd
transactionSendGtuCmd =
  command
    "send-gtu"
    (info
      (TransactionSendGtu <$>
        strOption (long "receiver" <> metavar "RECEIVER-ACCOUNT" <> help "address of the receiver") <*>
        option auto (long "amount" <> metavar "GTU-AMOUNT" <> help "amount of GTUs to send") <*>
        transactionCfgParser)
      (progDesc "transfer GTU from one account to another account (sending to contracts is currently not supported with this method - use 'transaction submit')"))

accountCmds :: Mod CommandFields Cmd
accountCmds =
  command
    "account"
    (info
      (AccountCmd <$>
        (hsubparser
          (accountShowCmd <>
           accountListCmd)))
      (progDesc "commands for inspecting accounts"))

accountShowCmd :: Mod CommandFields AccountCmd
accountShowCmd =
  command
    "show"
    (info
       (AccountShow <$>
         strArgument (metavar "ADDRESS" <> help "address of the account") <*>
         optional (strOption (long "block" <> metavar "BLOCK" <> help "hash of the block")))
       (progDesc "display account details"))

accountListCmd :: Mod CommandFields AccountCmd
accountListCmd =
  command
    "list"
    (info
       (AccountList <$>
         optional (strOption (long "block" <> metavar "BLOCK" <> help "hash of the block")))
       (progDesc "list all accounts"))

moduleCmds :: Mod CommandFields Cmd
moduleCmds =
  command
    "module"
    (info
      (ModuleCmd <$>
        (hsubparser
          (moduleShowCmd <>
           moduleListCmd <>
           moduleDeployCmd)))
      (progDesc "commands for inspecting and deploying modules"))

moduleShowCmd :: Mod CommandFields ModuleCmd
moduleShowCmd =
  command
    "show"
    (info
      (ModuleShow <$>
        strArgument (metavar "REF" <> help "reference ID of the module") <*>
        optional (strOption (long "block" <> metavar "BLOCK" <> help "hash of the block")))
      (progDesc "display module source code"))

moduleListCmd :: Mod CommandFields ModuleCmd
moduleListCmd =
  command
    "list"
    (info
      (ModuleList <$>
        optional (strOption (long "block" <> metavar "BLOCK" <> help "hash of the block")))
      (progDesc "list all modules at given (default: \"best\") block"))

moduleDeployCmd :: Mod CommandFields ModuleCmd
moduleDeployCmd =
  command
    "deploy"
    (info
      (ModuleDeploy <$>
        strArgument (metavar "MODLE-NAME" <> help "name of the module to deploy") <*>
        transactionCfgParser
      )
      (progDesc "deploy module"))

contractCmds :: Mod CommandFields Cmd
contractCmds =
  command
    "contract"
    (info
      (ContractCmd <$>
        (hsubparser
          (contractShowCmd <>
           contractListCmd <>
           contractInitCmd)))
      (progDesc "commands for inspecting and initializing smart contracts"))

contractShowCmd :: Mod CommandFields ContractCmd
contractShowCmd =
  command
    "show"
    (info
      (ContractShow <$>
        strArgument (metavar "ADDRESS" <> help "address of the contract") <*>
        optional (strOption (long "block" <> metavar "BLOCK" <> help "hash of the block")))
      (progDesc "display contract state at given (default: \"best\") block"))

contractListCmd :: Mod CommandFields ContractCmd
contractListCmd =
  command
    "list"
    (info
      (ContractList <$>
        optional (strOption (long "block" <> metavar "BLOCK" <> help "hash of the block")))
    (progDesc "list all contracts on a specific (default: \"best\") block"))

contractInitCmd :: Mod CommandFields ContractCmd
contractInitCmd =
  command
    "init"
    (info
      (ContractInit <$>
        strOption (long "module" <> metavar "MODULE" <> help "module containing the contract") <*>
        strOption (long "name" <> metavar "NAME" <> help "name of the contract in the module") <*>
        option auto (long "amount" <> metavar "AMOUNT" <> help "amount of GTU to transfer to the contract") <*>
        transactionCfgParser)
      (progDesc "initialize contract from already deployed module"))

configCmds :: Mod CommandFields Cmd
configCmds =
  command
    "config"
    (info
      (ConfigCmd <$>
        (hsubparser
          configDumpCmd))
      (progDesc "commands for inspecting and chaning local configuration"))

configDumpCmd :: Mod CommandFields ConfigCmd
configDumpCmd =
  command
    "dump"
    (info
      (pure ConfigDump)
      (progDesc "dump configuration"))

consensusCmds :: Mod CommandFields Cmd
consensusCmds =
  command
    "consensus"
    (info
      (ConsensusCmd <$>
        (hsubparser
          (consensusStatusCmd <>
           consensusShowParametersCmd)))
      (progDesc "commands for inspecting chain health (branching, finalization), block content/history (including listing transactions), election (Birk) and reward/minting parameters"))

consensusStatusCmd :: Mod CommandFields ConsensusCmd
consensusStatusCmd =
  command
    "status"
    (info
      (pure ConsensusStatus)
      (progDesc "list various parameters related to the state of the consensus protocol"))

consensusShowParametersCmd :: Mod CommandFields ConsensusCmd
consensusShowParametersCmd =
  command
    "show-parameters"
    (info
      (ConsensusShowParameters <$>
        optional (strOption (long "block" <> metavar "BLOCK" <> help "hash of the block")) <*>
        switch (long "include-bakers" <> help "include list of bakers"))
      (progDesc "show election parameters for given (default: \"best\" block)"))

blockCmds :: Mod CommandFields Cmd
blockCmds =
  command
    "block"
    (info
      (BlockCmd <$>
        (hsubparser
          (blockShowCmd)))
      (progDesc "..."))

blockShowCmd :: Mod CommandFields BlockCmd
blockShowCmd =
  command
    "show"
    (info
      (BlockShow <$>
        optional (strOption (long "block" <> metavar "BLOCK" <> help "hash of the block")))
      (progDesc "show election parameters for given (default: \"best\" block)"))
