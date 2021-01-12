{-# OPTIONS_GHC -Wno-deprecations #-}
{-# LANGUAGE OverloadedStrings #-}
module SimpleClientTests.BackupSpec where

import Concordium.Client.Config
import Concordium.Client.Encryption
import Concordium.Client.Export
import Concordium.Client.Types.Account
import Concordium.Common.Version (Versioned(..))
import qualified Concordium.Crypto.ByteStringHelpers as BSH
import qualified Concordium.ID.Types as IDTypes
import qualified Concordium.Types as Types
import Concordium.Types.HashableTo (getHash)

import qualified Data.Aeson as AE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LazyBS
import qualified Data.HashMap.Strict as M
import Test.Hspec

exampleAccountAddress1 :: IDTypes.AccountAddress
Right exampleAccountAddress1 = IDTypes.addressFromText "2zR4h351M1bqhrL9UywsbHrP3ucA1xY3TBTFRuTsRout8JnLD6"

-- |dummy accountconfig, for testing export/import 
exampleAccountConfigWithKeysAndName :: AccountConfig
exampleAccountConfigWithKeysAndName =
  AccountConfig
  { acAddr = NamedAddress { naName = Just "name" , naAddr = exampleAccountAddress1 }
  , acKeys = M.fromList [ (11,
                           EncryptedAccountKeyPairEd25519 {
                              verifyKey=vk1
                              , encryptedSignKey = EncryptedJSON (EncryptedText {
                                                                     etMetadata = EncryptionMetadata {
                                                                         emEncryptionMethod = AES256,
                                                                           emKeyDerivationMethod = PBKDF2SHA256,
                                                                           emIterations = 100000,
                                                                           emSalt = "sQ8NG/fBLdLuuLd1ARlAqw==",
                                                                           emInitializationVector = "z6tTcT5ko8vS2utlwwNvbw=="},
                                                                       etCipherText = "9ltKSJtlkiBXY/kU8huA4GoCaGNjy8M2Ym2SOtlg1ay6lfI9o95sXJ1cjcQ2b8gV+WddwS7ile8ZhIr8es58pTaM8PczlLbKBCSJ11R2iqw="})
                              })
                        , ( 2,
                            EncryptedAccountKeyPairEd25519 {
                              verifyKey=vk2
                              , encryptedSignKey = EncryptedJSON (EncryptedText {
                                                                     etMetadata = EncryptionMetadata {
                                                                         emEncryptionMethod = AES256,
                                                                         emKeyDerivationMethod = PBKDF2SHA256,
                                                                         emIterations = 100000,
                                                                         emSalt = "slzkcKo8IPymU5t7jamGQQ==",
                                                                         emInitializationVector = "NXbbI8Cc3AXtaG/go+L+FA=="},
                                                                     etCipherText = "hV5NemYi36f3erxCE8sC/uUdHKe1+2OrP3JVYVtBeUqn3QrOm8dlJcAd4mk7ufogJVyv0OR56w/oKqQ7HG8/UycDYtBlubGRHE0Ym4LCoqY="})
                              })]
  , acThreshold = 2
  , acEncryptionKey = Just EncryptedText {
      etMetadata = EncryptionMetadata {
          emEncryptionMethod = AES256,
          emIterations = 100000,
          emSalt = "w7pmsDi1K4bWf+zkLCuzVw==",
          emInitializationVector = "EXhd7ctFeqKvaA0P/oB8wA==",
          emKeyDerivationMethod = PBKDF2SHA256
          },
      etCipherText = "pYvIywCAMLhvag1EJmGVuVezGsNvYn24zBnB6TCTkwEwOH50AOrx8NAZnVuQteZMQ7k7Kd7a1RorSxIQI1H/WX+Usi8f3VLnzdZFJmbk4Cme+dcgAbI+wWr0hisgrCDl"
      }}
  where -- s1 = "6d00a10ccac23d2fd0bea163756487288fd19ff3810e1d3f73b686e60d801915"
        v1 = "c825d0ada6ebedcdf58b78cf4bc2dccc98c67ea0b0df6757f15c2b639e09f027"
        -- s2 = "9b301aa72d991d720750935de632983f1854d701ada3e5b763215d0802d5541c"
        v2 = "f489ebb6bec1f44ca1add277482c1a24d42173f2dd2e1ba9e79ed0ec5f76f213"
        -- (Just sk1) = BSH.deserializeBase16 s1
        (Just vk1) = BSH.deserializeBase16 v1
        -- (Just sk2) = BSH.deserializeBase16 s2
        (Just vk2) = BSH.deserializeBase16 v2

exampleContractNameMap :: ContractNameMap
exampleContractNameMap = M.fromList [("contrA", mkContrAddr 0 0), ("contrB", mkContrAddr 42 0), ("contrC", mkContrAddr 42 4200)]
  where mkContrAddr index subindex = Types.ContractAddress (Types.ContractIndex index) (Types.ContractSubindex subindex)

exampleModuleNameMap :: ModuleNameMap
exampleModuleNameMap = M.fromList [("modA", modRef1), ("modB", modRef2)]
  where
    modRef1 = Types.ModuleRef $ getHash ("ref1" :: BS.ByteString) -- Hash: de0cd794099a5e03c2131d662d423164111d3b78d5122970197cd7e1937ed0e4
    modRef2 = Types.ModuleRef $ getHash ("ref2" :: BS.ByteString) -- Hash: 3bdc9752a50026c173ce5e1e344b09bc131b04ba15e9f870e23c53490a51b840

exampleConfigBackup :: ConfigBackup
exampleConfigBackup = ConfigBackup
  { cbAccounts = [exampleAccountConfigWithKeysAndName]
  , cbContractNameMap = exampleContractNameMap
  , cbModuleNameMap = exampleModuleNameMap
  }

-- | Json generated by exporting exampleAccountConfigWithKeysAndName with v1 serialisation and no password
unencryptedBackupv1 :: BS.ByteString
unencryptedBackupv1 = LazyBS.toStrict "{\"contents\":{\"value\":[{\"address\":{\"address\":\"2zR4h351M1bqhrL9UywsbHrP3ucA1xY3TBTFRuTsRout8JnLD6\",\"name\":\"name\"},\"accountEncryptionKey\":{\"metadata\":{\"encryptionMethod\":\"AES-256\",\"iterations\":100000,\"salt\":\"w7pmsDi1K4bWf+zkLCuzVw==\",\"initializationVector\":\"EXhd7ctFeqKvaA0P/oB8wA==\",\"keyDerivationMethod\":\"PBKDF2WithHmacSHA256\"},\"cipherText\":\"pYvIywCAMLhvag1EJmGVuVezGsNvYn24zBnB6TCTkwEwOH50AOrx8NAZnVuQteZMQ7k7Kd7a1RorSxIQI1H/WX+Usi8f3VLnzdZFJmbk4Cme+dcgAbI+wWr0hisgrCDl\"},\"threshold\":2,\"accountKeys\":{\"2\":{\"encryptedSignKey\":{\"metadata\":{\"encryptionMethod\":\"AES-256\",\"iterations\":100000,\"salt\":\"slzkcKo8IPymU5t7jamGQQ==\",\"initializationVector\":\"NXbbI8Cc3AXtaG/go+L+FA==\",\"keyDerivationMethod\":\"PBKDF2WithHmacSHA256\"},\"cipherText\":\"hV5NemYi36f3erxCE8sC/uUdHKe1+2OrP3JVYVtBeUqn3QrOm8dlJcAd4mk7ufogJVyv0OR56w/oKqQ7HG8/UycDYtBlubGRHE0Ym4LCoqY=\"},\"verifyKey\":\"f489ebb6bec1f44ca1add277482c1a24d42173f2dd2e1ba9e79ed0ec5f76f213\",\"schemeId\":\"Ed25519\"},\"11\":{\"encryptedSignKey\":{\"metadata\":{\"encryptionMethod\":\"AES-256\",\"iterations\":100000,\"salt\":\"sQ8NG/fBLdLuuLd1ARlAqw==\",\"initializationVector\":\"z6tTcT5ko8vS2utlwwNvbw==\",\"keyDerivationMethod\":\"PBKDF2WithHmacSHA256\"},\"cipherText\":\"9ltKSJtlkiBXY/kU8huA4GoCaGNjy8M2Ym2SOtlg1ay6lfI9o95sXJ1cjcQ2b8gV+WddwS7ile8ZhIr8es58pTaM8PczlLbKBCSJ11R2iqw=\"},\"verifyKey\":\"c825d0ada6ebedcdf58b78cf4bc2dccc98c67ea0b0df6757f15c2b639e09f027\",\"schemeId\":\"Ed25519\"}}}],\"v\":1},\"type\":\"unencrypted\"}"

-- | Json generated by exporting exampleAccountConfigWithKeysAndName with v1 serialisation and password "testpassword"
encryptedBackupv1 :: BS.ByteString
encryptedBackupv1 = LazyBS.toStrict "{\"contents\":{\"metadata\":{\"encryptionMethod\":\"AES-256\",\"iterations\":100000,\"salt\":\"L5a2AoDsqA5f1bv0p0TN4w==\",\"initializationVector\":\"VPyjZ2XOjq2p62Mj+kBfVA==\",\"keyDerivationMethod\":\"PBKDF2WithHmacSHA256\"},\"cipherText\":\"oZDDtlwURYpLe5yAcNKRdKCzQbEaKInJ9p6MrFeCpbj13f6GKjcq/yGLPS8H+v94GuAtVkW2KmN4WR+kJZjz6skbItlJq3eXBjOo51oBvWbPxSD/e6N9ckJOxXvauXTZtb+DFm4d3RlX10EFM62XUPJg1pN3ZQYdwRiStUY+4jtcz6TnB6cIlvwFyErYxzLIT5NPqA/LUchtwsD/lPBTZzZYAS/CQRFcHViBnlvzcxQ2Lp6l8l0z8BZIQDsFiDgY9sHzNHn10U+UdfnLw66Yo2ViS02OJ9soRgbScVV0zeIpcALcDK9+cNhKPIlg4smBAPJavgf7KtOxVYVmod9IBckuZyuHmrsmXy2wbOHhS35aD2qslBdwUnmOzfhtpT1DOiIwBm2wVANYVg8/wIU/6h/PrbY72V1zblR87Q7trni3/ndst5YRoU50nFEaAa0HdbrbkE62UwWlnSww72PQOR//jBzQ+SACOS7Imy0H2xkpNIR0NuZ7TtAvs4svp0gadiYKD8s0YwlQ37kf30a9mo0FQgBzYXxTOjr1syZi4UuRkml6ZBbuFWilxnQon4eO5FjsICtXaK1s1b7tgJLLCBsobIcu9WrFYTFKhb3ur/+nBxb86gCPaqIrjSA4ERVVr8j1L9VnebJjLQKuU14njqItlO+uubhii4bb8Q4H+XpNJSlYsLCSf77jTCznjBJrw15SpFKKAdiVPPb1LyeUOMPnZOeun65FfblsxlkG8X6I1HBorkOD6QkBaSwXN0DLMorlQPgFU9l61Kcm6wtRFx2SLyu+5Gd+u/fWwgePScEeNX2gJJlzQgXDdL4l2tJbBCU0qLIEQPpjbg+8QRzh6/zd47R8WbLAcwRAU/jNSOrDHIgN0lTcWggxN3evZYT4xt8fzA6WMEwzmNY7UsCjW4gWmvdY6sEgqvoUL6pLJAHUVtOICeTl19j/7AxHwyt+/rT4DFLd35z7lYvGq16QvVIA8NGJx8FFj0Z3Vjire7EeV2b6JpIwfUpQSuBQD8ieIXGrOC3dAvubO7pYkQ1MADAUBKnAgVJA4Z54wvUxACZTRcDaksI/wQEAHNV0jGQd/G1nkzeQzqzcyfHmoNxbnTA6qnbKI3k2aAlqsMW6MDZ/xhRF+hf5H+L0FcoG7jY+GKZWAB/oRIPXrH8XH1tm58TM2lhfkTY1RdD6DCKthOuzsJXR1XqPMvEwgmwfAFMPNjqSdN6tB3Errr6xVm65/Wd57eOC35E5AUMroTBm7Qqfcbme1+sWWS05yikDTcAQQG9M7Vs/nr6G+hDK+880Pbp4kEeIa1SLZcc6W3ZPZhx9S0ID/Gfj810dXm0ROMe+H4fr5LNkhiAcAu1gFzF6krxbfwYen5nw87xGyvEiK21MD5Ub5ZPDUehuAnkxVyjpBkANNKtbjdUELPGPUUgJa1IjbDF3m5cyRk1ajsXex12Tk5Fglf+Kd6seXvi/1dSmjf2cQDkIk+tt/OaHa0mk48HwEBLSGPa8etK4QAAGTM4zJXMHPs7OjiIpAThh+bxkgPtOE+e62k/+3XL7BQWa4AnMnI8pIFNjfuEAfnxkuW9F+hQaVFmDJrxJe3r618eD89vtsp+pk+EwRGv2s2rBadrHgZMHKo86QVHoUPxfQTeVcF+A4DZp6q7MnVnWu0J9hTAeWOcha7UL0Ti8h5n7BoTAt2/2NzWHIIyLLTPWNmyNmfruBlMVd2AR2bcgetbBR1tJctDvpCPlNdhwD0qya6hxW8IF7xWdKLwdFOw1W7nmI6kRltftDvFg1rtsPhBsudyGIxvAvxz4+BCRby5E1VjjwNTUJG5ypuHYzgEq+IJUJ/y2l+voZbad/unLO1Bb\"},\"type\":\"encrypted\"}"

testPassword :: Password
testPassword = Password{getPassword = "testpassword"}

testPassword2 :: Password
testPassword2 = Password{getPassword = "anotherTestPassword"}

versionedExampleConfigBackup :: VersionedConfigBackup
versionedExampleConfigBackup = VersionedConfigBackup (Versioned 1 exampleConfigBackup)

backupSpec :: Spec
backupSpec = describe "Testing backup import/export" $ do
    specify "JSON decode is inverse of decode for VersionedConfigBackup" $ do
      (AE.eitherDecode . AE.encode $ versionedExampleConfigBackup) `shouldBe` Right versionedExampleConfigBackup
    specify "export then import with password" $ do
        exported <- configExport exampleConfigBackup $ Just testPassword
        x' <- configImport exported $ return testPassword
        x' `shouldBe` (Right exampleConfigBackup)
    specify "export then import without password" $ do
        exported <- onfigExport exampleConfigBackup Nothing
        x' <- configImport exported (return testPassword)
        x' `shouldBe` (Right exampleConfigBackup)
    -- specify "import unencrypted accountconfig V1" $ do
    --     -- Tests that we can import accountconfig's with v1.0 serialisation
    --     x' <- configImport unencryptedBackupv1 (return testPassword)
    --     x' `shouldBe` (Right exampleConfigBackup)
    -- specify "import encrypted accountconfig V1" $ do
    --     -- Tests that we can import encrypted accountconfig's with v1.0 serialisation
    --     x' <- configImport encryptedBackupv1 (return testPassword)
    --     x' `shouldBe` (Right exampleConfigBackup)
