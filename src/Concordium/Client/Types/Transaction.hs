{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Concordium.Client.Types.Transaction where

import           Concordium.Crypto.SignatureScheme   (SchemeId (..),
                                                      SignKey (..))
import           Concordium.GlobalState.Transactions
import qualified Concordium.ID.Account               as AH
import qualified Concordium.ID.Types                 as IDTypes
import qualified Concordium.Scheduler.Types          as Types
import           Concordium.Types
import           Data.Aeson                          as AE
import qualified Data.Aeson.TH                       as AETH
import           Data.Aeson.Types                    (typeMismatch)
import qualified Data.ByteString                     as BS
import qualified Data.ByteString.Base16              as BS16
import qualified Data.ByteString.Short               as BSS
import           Data.Serialize                      as S
import           Data.Text                           hiding (length, map)
import qualified Data.Text.Encoding                  as Text
import           Data.Word
import           GHC.Generics                        (Generic)

-- Number
instance FromJSON Nonce where
  parseJSON v = Nonce <$> parseJSON v

-- Number
instance FromJSON Energy where
  parseJSON v = Energy <$> parseJSON v

-- Number
instance FromJSON Amount where
  parseJSON v = Amount <$> parseJSON v

-- Data (serializes with `putByteString :: Bytestring -> Put`)
instance FromJSON BlockHash where
  parseJSON v = do
    hash <- parseJSON v
    case S.decode . fst . BS16.decode . Text.encodeUtf8 $ hash of
      Left e  -> fail e
      Right n -> return n

instance FromJSON AccountAddress where
  parseJSON v = AH.base58decodeAddr <$> parseJSON v
  parseJSONList v = map AH.base58decodeAddr <$> parseJSONList v

instance FromJSON Address where
  parseJSON (Object v) = do
    r <- v .:? "accountAddress"
    case r of
      Nothing -> AddressContract <$> (v .: "contractAddress")
      Just a  -> return (AddressAccount a)
  parseJSON invalid = typeMismatch "Address" invalid

-- Length + data (serializes with `put :: Bytestring -> Put`)
instance FromJSON IDTypes.AccountEncryptionKey where
  parseJSON v = do
    aek <- parseJSON v
    let plainBs = fst . BS16.decode . Text.encodeUtf8 $ aek
    case S.decode . flip BS.append plainBs $
         S.encode (fromIntegral . BS.length $ plainBs :: Word16) of
      Left e  -> fail e
      Right n -> return n

-- Data (serializes with `putByteString :: Bytestring -> Put`)
instance FromJSON BakerElectionVerifyKey where
  parseJSON v = do
    b16 <- parseJSON v
    case S.decode . fst . BS16.decode . Text.encodeUtf8 $ b16 of
      Left e  -> fail e
      Right n -> return n

-- Data (serializes with `putByteString :: Bytestring -> Put`)
instance FromJSON Types.Proof where
  parseJSON v = fst . BS16.decode . Text.encodeUtf8 <$> parseJSON v

-- Number
instance FromJSON BakerId where
  parseJSON v = BakerId <$> parseJSON v

-- |Transaction header type
-- To be populated when deserializing a JSON object.
data TransactionJSONHeader =
  TransactionJSONHeader
  -- |Verification key of the sender.
    { thSenderKey        :: IDTypes.AccountVerificationKey
  -- |Nonce of the account. If not present it should be derived
  -- from the context or queried to the state
    , thNonce            :: Maybe Nonce
  -- |Amount dedicated for the execution of this transaction.
    , thGasAmount        :: Energy
  -- |Pointer to a finalized block. If this is too out of date at
  -- the time of execution the transaction is dropped
    , thFinalizedPointer :: BlockHash
    }
  deriving (Eq, Show)

data ModuleSource
  = ByName Text
  | FromSource Text
  deriving (Eq, Show)

-- |Payload of a transaction
data TransactionJSONPayload
  = DeployModuleFromSource
      { moduleSource :: FilePath
      } -- ^ Read a serialized module from a file and deploy it.
  | DeployModule
      { moduleName :: Text
      } -- ^ Deploys a blockchain-ready version of the module, as retrieved from the Context
  | InitContract
      { amount       :: Amount
      , moduleName   :: Text
      , contractName :: Text
      , parameter    :: Text
      } -- ^ Initializes a specific Contract in a Module
  | Update
      { moduleName :: Text
      , amount     :: Amount
      , address    :: ContractAddress
      , message    :: Text
      } -- ^ Sends a specific message to a Contract
  | Transfer
      { toaddress :: Address
      , amount    :: Amount
      } -- ^ Transfers specific amount to the recipent
  | DeployCredential
      { credential :: IDTypes.CredentialDeploymentInformation
      } -- ^ Deploy credentials, creating a new account if one does not yet exist.
  | DeployEncryptionKey
      { key :: IDTypes.AccountEncryptionKey
      }
  | AddBaker
      { electionVerifyKey  :: BakerElectionVerifyKey
      , signatureVerifyKey :: BakerSignVerifyKey
      , bakerAccount       :: AccountAddress
      , proof              :: Types.Proof
      }
  | RemoveBaker
      { removeId :: BakerId
      , proof    :: Types.Proof
      }
  | UpdateBakerAccount
      { bakerId        :: BakerId
      , accountAddress :: AccountAddress
      , proof          :: Types.Proof
      }
  | UpdateBakerSignKey
      { bakerId    :: BakerId
      , newSignKey :: BakerSignVerifyKey
      , proof      :: Types.Proof
      }
  | DelegateStake
      { bakerId :: BakerId
      }
  deriving (Show, Generic)

AETH.deriveFromJSON
  (AETH.defaultOptions
     {AETH.sumEncoding = AETH.TaggedObject "transactionType" "contents"})
  ''TransactionJSONPayload

-- |Transaction as retrieved from a JSON object
data TransactionJSON =
  TransactionJSON
    { metadata :: TransactionJSONHeader
    , payload  :: TransactionJSONPayload
    , signKey  :: SignKey
    }
  deriving (Generic, Show)

instance AE.FromJSON TransactionJSON where
  parseJSON (Object v) = do
    thSenderKey <- v .: "verifyKey"
    thNonce <- v .:? "nonce"
    thGasAmount <- v .: "gasAmount"
    thFinalizedPointer <- v .: "finalizedPointer"
    let tHeader = TransactionJSONHeader {..}
    tPayload <- v .: "payload"
    tSignKey <-
      SignKey . BSS.toShort . fst . BS16.decode . Text.encodeUtf8 <$>
      (v .: "signKey")
    return $ TransactionJSON tHeader tPayload tSignKey
  parseJSON invalid = typeMismatch "Transaction" invalid

-- |Creates a proper transaction header populating the Nonce if needed
makeTransactionHeaderWithNonce ::
     TransactionJSONHeader -> Types.Nonce -> Types.TransactionHeader
makeTransactionHeaderWithNonce (TransactionJSONHeader sk _ ga fp) nonce =
  makeTransactionHeader Ed25519 sk nonce ga fp
