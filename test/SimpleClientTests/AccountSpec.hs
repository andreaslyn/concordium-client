module SimpleClientTests.AccountSpec where

import Concordium.Client.Cli
import Concordium.Client.Output
import Concordium.Client.Runner
import qualified Concordium.ID.Types as IDTypes
import qualified Concordium.Types as Types
import qualified Concordium.Types.Transactions as Types
import qualified Concordium.Crypto.ByteStringHelpers as BSH

import SimpleClientTests.QueryTransaction

import Control.Monad.Writer
import Data.Map.Strict as Map
import Data.Text (Text)

import Test.Hspec

exampleAddress :: Text
exampleAddress = "2zR4h351M1bqhrL9UywsbHrP3ucA1xY3TBTFRuTsRout8JnLD6"

accountSpec :: Spec
accountSpec = describe "account" $ do
  printAccountInfoSpec
  printCredSpec

exampleAccountInfoResult :: Maybe Types.BakerId -> [IDTypes.CredentialDeploymentValues] -> AccountInfoResult
exampleAccountInfoResult d cs = AccountInfoResult
                                { airAmount = Types.Amount 1
                                , airNonce = Types.Nonce 2
                                , airDelegation = d
                                , airCredentials = zip (repeat 0) cs }

exampleCredentials :: IDTypes.Policy -> IDTypes.CredentialDeploymentValues
exampleCredentials p = IDTypes.CredentialDeploymentValues
                       { IDTypes.cdvAccount = IDTypes.ExistingAccount acc
                       , IDTypes.cdvRegId = regId
                       , IDTypes.cdvIpId = IDTypes.IP_ID 21
                       , IDTypes.cdvThreshold = IDTypes.Threshold 1
                       , IDTypes.cdvArData = [IDTypes.ChainArData
                                              { IDTypes.ardName = IDTypes.ARName 0
                                              , IDTypes.ardIdCredPubShare = share
                                              , IDTypes.ardIdCredPubShareNumber = IDTypes.ShareNumber 0 }]
                       , IDTypes.cdvPolicy = p }
  where (Right acc) = IDTypes.addressFromText exampleAddress
        (Just regId) = BSH.deserializeBase16 "a1355cd1e5e2f4b712c4302f09f045f194c708e5d0cae3b980f53ae3244fc7357d688d97be251a86735179871f03a46f"
        (Just share) = BSH.deserializeBase16 "a1355cd1e5e2f4b712c4302f09f045f194c708e5d0cae3b980f53ae3244fc7357d688d97be251a86735179871f03a46fa1355cd1e5e2f4b712c4302f09f045f194c708e5d0cae3b980f53ae3244fc7357d688d97be251a86735179871f03a46f"

examplePolicyWithoutItems :: IDTypes.Policy
examplePolicyWithoutItems = IDTypes.Policy { IDTypes.pExpiry = 9999999999, IDTypes.pItems = Map.empty }

examplePolicyWithOneItem :: IDTypes.Policy
examplePolicyWithOneItem = IDTypes.Policy
                           { IDTypes.pExpiry = 9999999999
                           , IDTypes.pItems = Map.fromList [(IDTypes.AttributeTag 1, IDTypes.AttributeValue 2)] }

examplePolicyWithTwoItems :: IDTypes.Policy
examplePolicyWithTwoItems = IDTypes.Policy
                            { IDTypes.pExpiry = 9999999999
                            , IDTypes.pItems = Map.fromList [(IDTypes.AttributeTag 1, IDTypes.AttributeValue 2), (IDTypes.AttributeTag 3, IDTypes.AttributeValue 4)] }

examplePolicyWithItemOutOfRange :: IDTypes.Policy
examplePolicyWithItemOutOfRange = IDTypes.Policy
                                  { IDTypes.pExpiry = 9999999999
                                  , IDTypes.pItems = Map.fromList [(IDTypes.AttributeTag 255, IDTypes.AttributeValue 1)] }

printAccountInfoSpec :: Spec
printAccountInfoSpec = describe "printAccountInfo" $ do
  specify "without delegation nor credentials" $ p exampleAddress (exampleAccountInfoResult Nothing []) `shouldBe`
    [ "Address:    2zR4h351M1bqhrL9UywsbHrP3ucA1xY3TBTFRuTsRout8JnLD6"
    , "Amount:     1 GTU"
    , "Nonce:      2"
    , "Delegation: none"
    , ""
    , "Credentials: none" ]
  specify "with delegation" $ p exampleAddress (exampleAccountInfoResult (Just 1) []) `shouldBe`
    [ "Address:    2zR4h351M1bqhrL9UywsbHrP3ucA1xY3TBTFRuTsRout8JnLD6"
    , "Amount:     1 GTU"
    , "Nonce:      2"
    , "Delegation: 1"
    , ""
    , "Credentials: none" ]
  specify "with one credential" $ p exampleAddress (exampleAccountInfoResult (Just 1) [exampleCredentials examplePolicyWithoutItems]) `shouldBe`
    [ "Address:    2zR4h351M1bqhrL9UywsbHrP3ucA1xY3TBTFRuTsRout8JnLD6"
    , "Amount:     1 GTU"
    , "Nonce:      2"
    , "Delegation: 1"
    , ""
    , "Credentials:"
    , "* a1355cd1e5e2f4b712c4302f09f045f194c708e5d0cae3b980f53ae3244fc7357d688d97be251a86735179871f03a46f:"
    , "  - expiration: Sat, 20 Nov 2286 17:46:39 UTC"
    , "  - revealed attributes: none" ]
  specify "with two credentials" $ p exampleAddress (exampleAccountInfoResult (Just 1) [ exampleCredentials examplePolicyWithoutItems
                                                                                       , exampleCredentials examplePolicyWithTwoItems ]) `shouldBe`
    [ "Address:    2zR4h351M1bqhrL9UywsbHrP3ucA1xY3TBTFRuTsRout8JnLD6"
    , "Amount:     1 GTU"
    , "Nonce:      2"
    , "Delegation: 1"
    , ""
    , "Credentials:"
    , "* a1355cd1e5e2f4b712c4302f09f045f194c708e5d0cae3b980f53ae3244fc7357d688d97be251a86735179871f03a46f:"
    , "  - expiration: Sat, 20 Nov 2286 17:46:39 UTC"
    , "  - revealed attributes: none"
    , "* a1355cd1e5e2f4b712c4302f09f045f194c708e5d0cae3b980f53ae3244fc7357d688d97be251a86735179871f03a46f:"
    , "  - expiration: Sat, 20 Nov 2286 17:46:39 UTC"
    , "  - revealed attributes: CreationTime=2, LastName=4" ]
  specify "with one credential - verbose" $
    (execWriter $ printAccountInfo exampleAddress (exampleAccountInfoResult (Just 1) [exampleCredentials examplePolicyWithoutItems]) True) `shouldBe`
      [ "Address:    2zR4h351M1bqhrL9UywsbHrP3ucA1xY3TBTFRuTsRout8JnLD6"
      , "Amount:     1 GTU"
      , "Nonce:      2"
      , "Delegation: 1"
      , ""
      , "Credentials:"
      , "{\n\
        \    \"ipIdentity\": 21,\n\
        \    \"regId\": \"a1355cd1e5e2f4b712c4302f09f045f194c708e5d0cae3b980f53ae3244fc7357d688d97be251a86735179871f03a46f\",\n\
        \    \"arData\": [\n\
        \        {\n\
        \            \"idCredPubShareNumber\": 0,\n\
        \            \"encIdCredPubShare\": \"a1355cd1e5e2f4b712c4302f09f045f194c708e5d0cae3b980f53ae3244fc7357d688d97be251a86735179871f03a46fa1355cd1e5e2f4b712c4302f09f045f194c708e5d0cae3b980f53ae3244fc7357d688d97be251a86735179871f03a46f\",\n\
        \            \"arIdentity\": 0\n\
        \        }\n\
        \    ],\n\
        \    \"account\": \"2zR4h351M1bqhrL9UywsbHrP3ucA1xY3TBTFRuTsRout8JnLD6\",\n\
        \    \"revocationThreshold\": 1,\n\
        \    \"policy\": {\n\
        \        \"revealedAttributes\": {},\n\
        \        \"expiryDate\": 9999999999\n\
        \    }\n\
        \}" ]
  where p addr res = execWriter $ printAccountInfo addr res False

printCredSpec :: Spec
printCredSpec = describe "printCred" $ do
  specify "without attributes" $ (p $ exampleCredentials examplePolicyWithoutItems) `shouldBe`
    [ "* a1355cd1e5e2f4b712c4302f09f045f194c708e5d0cae3b980f53ae3244fc7357d688d97be251a86735179871f03a46f:"
    , "  - expiration: Sat, 20 Nov 2286 17:46:39 UTC"
    , "  - revealed attributes: none" ]
  specify "with single attribute" $ (p $ exampleCredentials examplePolicyWithOneItem) `shouldBe`
    [ "* a1355cd1e5e2f4b712c4302f09f045f194c708e5d0cae3b980f53ae3244fc7357d688d97be251a86735179871f03a46f:"
    , "  - expiration: Sat, 20 Nov 2286 17:46:39 UTC"
    , "  - revealed attributes: CreationTime=2" ]
  specify "with two attributes" $ (p $ exampleCredentials examplePolicyWithTwoItems) `shouldBe`
    [ "* a1355cd1e5e2f4b712c4302f09f045f194c708e5d0cae3b980f53ae3244fc7357d688d97be251a86735179871f03a46f:"
    , "  - expiration: Sat, 20 Nov 2286 17:46:39 UTC"
    , "  - revealed attributes: CreationTime=2, LastName=4" ]
  specify "with attribute having key out of range" $ (p $ exampleCredentials examplePolicyWithItemOutOfRange) `shouldBe`
    [ "* a1355cd1e5e2f4b712c4302f09f045f194c708e5d0cae3b980f53ae3244fc7357d688d97be251a86735179871f03a46f:"
    , "  - expiration: Sat, 20 Nov 2286 17:46:39 UTC"
    , "  - revealed attributes: <255>=1" ]
  where p c = execWriter $ printCred c