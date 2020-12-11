{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE QuasiQuotes #-}
module Concordium.Client.Types.Contract.Parameter where

import Concordium.Client.Config (showCompactPrettyJSON, showPrettyJSON)
import qualified Concordium.Types as T
import Concordium.Client.Types.Contract.Schema

import Control.Monad (unless, when, zipWithM)
import Data.Aeson (FromJSON, Result, ToJSON, (.=))
import qualified Data.Aeson as AE
import qualified Data.Aeson.Types as AE
import Data.ByteString (ByteString)
import qualified Data.Char as Char
import qualified Data.HashMap.Strict as HM
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Scientific (Scientific, isFloating, toBoundedInteger)
import qualified Data.Serialize as S
import Data.String.Interpolate (i, iii)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Time as Time
import qualified Data.Time.Clock.POSIX as POSIX
import qualified Data.Time.RFC3339 as RFC3339
import qualified Data.Vector as V
import Data.Word (Word8, Word16, Word32, Word64)
import Lens.Micro.Platform ((^?), ix)
import Text.Read (readMaybe)

-- |Serialize JSON parameter to binary using `SchemaType` or fail with an error message.
encodeParameter :: SchemaType -> AE.Value -> Either String ByteString
encodeParameter typ params = S.runPut <$> putJSONUsingSchema typ params

-- |Create a `Serialize.Get` for decoding binary as specified by a `SchemaType` into JSON.
-- The `SchemaType` is pattern matched and for each variant, the corresponding binary
-- deserialization is used followed by the corresponding JSON serialization.
-- The Value that is returned should match what is expected from `putJSONUsingSchema` when using the same schema.
getJSONUsingSchema :: SchemaType -> S.Get AE.Value
getJSONUsingSchema typ = case typ of
  Unit -> return AE.Null
  Bool -> AE.Bool <$> S.get
  UInt8   -> AE.toJSON <$> S.getWord8
  UInt16  -> AE.toJSON <$> S.getWord16le
  UInt32  -> AE.toJSON <$> S.getWord32le
  UInt64  -> AE.toJSON <$> S.getWord64le
  Int8   -> AE.toJSON <$> S.getInt8
  Int16  -> AE.toJSON <$> S.getInt16le
  Int32  -> AE.toJSON <$> S.getInt32le
  Int64  -> AE.toJSON <$> S.getInt64le
  Amount -> AE.toJSON <$> (S.get :: S.Get AmountLE)
  AccountAddress  -> AE.toJSON <$> (S.get :: S.Get T.AccountAddress)
  ContractAddress -> AE.toJSON <$>
    (T.ContractAddress <$> (T.ContractIndex <$> S.getWord64le) <*> (T.ContractSubindex <$> S.getWord64le))
  Timestamp -> AE.toJSON . unixTimestampInMsToRFC3339 <$> S.getWord64le
  Duration -> AE.toJSON . durationToText <$> S.getWord64le
  Pair a b -> do
    l <- getJSONUsingSchema a
    r <- getJSONUsingSchema b
    return $ AE.toJSON [l, r]
  List sl elemType -> AE.toJSON <$> getListOfWithSizeLen sl (getJSONUsingSchema elemType)
  Set sl elemType  -> AE.toJSON <$> getListOfWithSizeLen sl (getJSONUsingSchema elemType)
  Map sl keyType valType -> AE.toJSON <$> getListOfWithSizeLen sl (S.getTwoOf (getJSONUsingSchema keyType) (getJSONUsingSchema valType))
  Array len elemType     -> AE.toJSON <$> getListOfWithKnownLen len (getJSONUsingSchema elemType)
  Struct fields -> AE.toJSON <$> getFieldsAsJSON fields
  Enum variants -> do
    idx <- if length variants <= 255
           then fromIntegral <$> S.getWord8
           else fromIntegral <$> S.getWord32le
    (name, fields) <- case variants ^? ix idx of
                      Just v -> return v
                      Nothing -> fail [i|Variant with index #{idx} does not exist for Enum.|]
    fields' <- getFieldsAsJSON fields
    return $ AE.object [name .= fields']
  where
    getFieldsAsJSON :: Fields -> S.Get AE.Value
    getFieldsAsJSON fields = case fields of
      Named pairs -> AE.toJSON . Map.fromList <$> mapM getPair pairs
      Unnamed xs  -> AE.toJSON <$> mapM getJSONUsingSchema xs
      None        -> return $ AE.Array mempty
      where getPair (k, v) = (k,) <$> getJSONUsingSchema v

    -- |Converts a unix timestamp in milliseconds to UTC in RFC3339-format.
    -- Example: 220966827870 -> "1977-01-01T11:40:27Z"
    -- FIXME: Currently looses the milliseconds (.87 in this example).
    unixTimestampInMsToRFC3339 :: Word64 -> Text
    unixTimestampInMsToRFC3339 = Text.pack . utcToRFC3339 . posixMillisecondsToUTCTime . fromIntegral
      where posixMillisecondsToUTCTime :: POSIX.POSIXTime -> Time.UTCTime
            posixMillisecondsToUTCTime ms = POSIX.posixSecondsToUTCTime s
              where s = ms / 1000

            utcToRFC3339 :: Time.UTCTime -> String
            utcToRFC3339 = RFC3339.formatTimeRFC3339 . Time.utcToZonedTime Time.utc

    -- |Convert a duration in milliseconds into text with a list of duration measures separated by a space.
    -- A measure is a non-negative integer followed by the unit (with no whitespace in between).
    -- The support units are: days (d), hours (h), minutes (m), seconds (s), milliseconds (ms).
    -- Measures that are 0 are omitted from the output (see example, where 'd' and 'ms' are omitted).
    -- Example: 5022000 -> "1h 23m 42s".
    durationToText :: Word64 -> Text
    durationToText t = Text.intercalate " " . filter (/= "") . map showTimeUnit $
                      [(d, "d"), (h, "h"), (m, "m"), (s, "s"), (ms, "ms")]
      where
        (d, rem0) = quotRem t dayInMs
        (h, rem1) = quotRem rem0 hrInMs
        (m, rem2) = quotRem rem1 minInMs
        (s, ms)   = quotRem rem2 secInMs

        showTimeUnit :: (Word64, Text) -> Text
        showTimeUnit (value, unit) = if value == 0
                                  then ""
                                  else [i|#{value}#{unit}|]

-- |Create a `Serialize.Put` for JSON using a `SchemaType`.
-- It goes through the JSON and SchemaType recursively, and
-- deserializes the JSON before serializing the values to binary.
-- A descriptive error message is shown if the JSON does not match
-- the expected format as specified by the `SchemaType`.
putJSONUsingSchema :: SchemaType -> AE.Value -> Either String S.Put
putJSONUsingSchema typ json = case (typ, json) of
  (Unit, AE.Null)     -> pure mempty
  (Bool, AE.Bool b)   -> pure $ S.put b
  (UInt8,   AE.Number x) -> S.putWord8    <$> fromScientific x UInt8
  (UInt16,  AE.Number x) -> S.putWord16le <$> fromScientific x UInt16
  (UInt32,  AE.Number x) -> S.putWord32le <$> fromScientific x UInt32
  (UInt64,  AE.Number x) -> S.putWord64le <$> fromScientific x UInt64
  (Int8,   AE.Number x) -> S.putInt8     <$> fromScientific x Int8
  (Int16,  AE.Number x) -> S.putInt16le  <$> fromScientific x Int16
  (Int32,  AE.Number x) -> S.putInt32le  <$> fromScientific x Int32
  (Int64,  AE.Number x) -> S.putInt64le  <$> fromScientific x Int64

  (Amount, amt@(AE.String _)) -> addTraceInfo $ (S.put :: S.Putter AmountLE) <$> (resToEither . AE.fromJSON $ amt)

  (AccountAddress, v@(AE.String _)) -> addTraceInfo $ (S.put :: S.Putter T.AccountAddress) <$> AE.parseEither AE.parseJSON v

  (ContractAddress, AE.Object obj) -> addTraceInfo $ case HM.toList obj of
    [("index", AE.Number idx)] -> putContrAddr idx 0
    [("index", AE.Number idx), ("subindex", AE.Number subidx)] -> putContrAddr idx subidx
    [("subindex", AE.Number subidx), ("index", AE.Number idx)] -> putContrAddr idx subidx
    _ -> Left [i|Invalid contract address. It should be an object with an 'index' and an optional 'subindex' field.|]

  (Timestamp, AE.String s) -> S.putWord64le <$> rfc3339ToUnixTimestampInMs s

  (Duration, AE.String s) -> S.putWord64le <$> textToDuration s

  (Pair ta tb, AE.Array vec) -> addTraceInfo $ case V.toList vec of
    [a, b] -> do
      putA <- putJSONUsingSchema ta a
      putB <- putJSONUsingSchema tb b
      pure $ putA <> putB
    _ -> Left [i|Invalid pair. It should have the form: [#{showCompactPrettyJSON ta}, #{showCompactPrettyJSON tb}].|]

  (List sl elemType, AE.Array vec) -> do
    let len = fromIntegral . V.length $ vec
        maxLen = maxSizeLen sl
    when (len > maxLen) $ Left $ tooLongError "List" maxLen len
    addTraceInfo $ putListLike sl elemType (V.toList vec)

  (Set sl elemType, AE.Array vec) -> do
    let len = fromIntegral . V.length $ vec
        maxLen = maxSizeLen sl
        ls = V.toList vec
    when (len > maxLen) $ Left $ tooLongError "Set" maxLen len
    addTraceInfo $ putListLike sl elemType ls

  (Map sl keyType valType, AE.Array vec) -> do
    let len = fromIntegral . V.length $ vec
        maxLen = maxSizeLen sl
        putLen = putLenWithSizeLen sl $ V.length vec
    when (len > maxLen) $ Left $ tooLongError "Map" maxLen len
    putElems <- mapM (putJSONUsingSchema (Pair keyType valType)) vec
    addTraceInfo $ pure . sequence_ $ V.cons putLen putElems

  (Array expectedLen elemType, AE.Array vec) -> do
    let ls = V.toList vec
        actualLen = length ls
    unless (actualLen == fromIntegral expectedLen) $ addTraceInfo
      $ Left [i|Expected length is #{expectedLen}, but actual length is #{actualLen}.|]
    addTraceInfo $ sequence_ <$> mapM (putJSONUsingSchema elemType) ls

  (Struct fields, val) -> addTraceInfo $ putJSONFields fields val

  (enum@(Enum variants), AE.Object obj) -> case HM.toList obj of
    [] -> Left [i|The object provided was empty, but it should have contained a variant of the following enum:\n#{showPrettyJSON enum}.|]
    [(name, fields)] -> case lookupItemAndIndex name variants of
      Nothing -> Left [i|Enum variant '#{name}' does not exist in:\n#{showPrettyJSON enum}|]
      Just (fieldTypes, idx) -> do
        let putLen = if length variants <= 255
                       then S.putWord8 $ fromIntegral idx
                       else S.putWord32le $ fromIntegral idx
        putJSONFields' <- putJSONFields fieldTypes fields `addTraceInfoOf` [i|In enum variant '#{name}'.|]
        pure $ putLen <> putJSONFields'
    _ -> Left [i|#{obj} had too many fields. It should contain a single variant of the following enum:\n#{showPrettyJSON enum}.|]

  (type_, value) -> Left [i|Expected value of type #{showCompactPrettyJSON type_}, but got: #{showCompactPrettyJSON value}.|]

  where
    putJSONFields :: Fields -> AE.Value -> Either String S.Put
    putJSONFields fields val = case (fields, val) of
      (Named pairs, AE.Object obj) -> do
        let ls = HM.toList obj
        let actualLen = length ls
        let expectedLen = length pairs
        when (actualLen /= expectedLen)
          $ Left [i|#{actualLen} fields were provided, but expected #{expectedLen} fields for type:\n#{showPrettyJSON fields}.|]
        putNamedUnordered <- mapM (lookupAndPut pairs) ls
        -- The fields entered might be in a different order, so we need to order them correctly.
        pure . mapM_ snd . List.sortOn fst $ putNamedUnordered

      (Unnamed types, AE.Array vec) -> do
        let ls = V.toList vec
        let expectedLen = length types
        let actualLen = length ls
        when (actualLen /= expectedLen)
          $ Left [i|#{actualLen} fields were provided, but it should have had #{expectedLen} according to its type:\n#{showPrettyJSON fields}.|]
        putUnnamed <- zipWithM putJSONUsingSchema types ls `addTraceInfoOf` [i|In #{showPrettyJSON vec}.|]
        pure . sequence_ $ putUnnamed

      (None, AE.Array vec) -> if V.null vec
                                then pure mempty
                                else Left [i|Expected an empty array to represent None, but got: #{showCompactPrettyJSON val}.|]

      (type_, value) -> Left [i|Expected value of type #{showCompactPrettyJSON type_}, but got: #{showCompactPrettyJSON value}.|]

    putListLike :: SizeLength -> SchemaType -> [AE.Value] -> Either String S.Put
    putListLike sl elemType xs = do
      let putLen = putLenWithSizeLen sl $ length xs
      putElems <- mapM (putJSONUsingSchema elemType) xs
      pure . sequence_ $ putLen : putElems

    putContrAddr :: Scientific -> Scientific -> Either String S.Put
    putContrAddr idx subidx = do
      idx' <- fromScientific idx UInt64
      subidx' <- fromScientific subidx UInt64
      pure $ S.putWord64le idx' <> S.putWord64le subidx'

    -- |The `SchemaType` should be a type of number.
    fromScientific :: (Integral i, Bounded i) => Scientific -> SchemaType -> Either String i
    fromScientific x numType = if isFloating x then Left [i|#{x} is a float, but it should have been of type #{numType}.|]
      else case toBoundedInteger x of
        Nothing -> Left [i|#{x} is out of bounds for type #{numType}.|]
        Just x' -> Right x'

    tooLongError :: String -> Integer -> Integer -> String
    tooLongError typeName maxLen actualLen =
      [i|The provided #{typeName} is too long. It has length #{actualLen} and the maximum is #{maxLen}.|]

    maxSizeLen :: SizeLength -> Integer
    maxSizeLen = \case
      One   -> toInteger (maxBound :: Word8)
      Two   -> toInteger (maxBound :: Word16)
      Four  -> toInteger (maxBound :: Word32)
      Eight -> toInteger (maxBound :: Word64)

    lookupAndPut :: [(Text, SchemaType)]     -- ^ The names and types for Named Fields.
                 -> (Text, AE.Value)         -- ^ A field name and a value.
                 -> Either String (Int, S.Put) -- ^ The index of the field in the particular Named Fields,
                                             --   used for subsequent ordering,
                                             --   and a putter for the value (or an error message).
    lookupAndPut types (name, value) = case lookupItemAndIndex name types of
          Nothing -> Left [i|'#{name}' is not a valid field in the type:\n#{showPrettyJSON (Named types)}.|]
          Just (typ', idx) -> ((idx, ) <$> putJSONUsingSchema typ' value) `addTraceInfoOf` [i|In field '#{name}'.|]

    lookupItemAndIndex :: Eq a => a -> [(a, b)] -> Maybe (b, Int)
    lookupItemAndIndex item thePairs = go item thePairs 0
      where go _ [] _ = Nothing
            go x ((a,b):pairs) idx = if x == a
                                    then Just (b, idx)
                                    else go x pairs (idx + 1)

    resToEither :: Result a -> Either String a
    resToEither (AE.Error str) = Left str
    resToEither (AE.Success a) = Right a

    addTraceInfo :: Either String a -> Either String a
    addTraceInfo = flip addTraceInfoOf [i|In #{showPrettyJSON json}.|]

    addTraceInfoOf :: Either String a -> String -> Either String a
    addTraceInfoOf (Left err) a = Left [i|#{err}\n#{a}|]
    addTraceInfoOf right _ = right

    -- |Converts a date in RFC3339-format to a unix timestamp in milliseconds.
    -- Unix timestamps are always in UTC.
    -- Returns an error message if input is invalid RFC3339 or the date is prior to '1970-01-01T00:00:00Z'.
    -- Example: "1977-01-01T12:00:27.87+00:20" -> Right 220966827870
    rfc3339ToUnixTimestampInMs :: Text -> Either String Word64
    rfc3339ToUnixTimestampInMs s = case RFC3339.parseTimeRFC3339 . Text.unpack $ s of
      Nothing -> Left [i|Invalid timestamp '#{s}'. Should be in a RFC3339 format.|]
      Just zonedTime -> utcTimeToTimestampInMs . Time.zonedTimeToUTC $ zonedTime
      where utcTimeToTimestampInMs :: Time.UTCTime -> Either String Word64
            utcTimeToTimestampInMs t
              | posixSeconds < 0 = Left [i|Invalid timestamp '#{s}'. Dates before '1970-01-01T00:00:00Z' are not supported|]
              | otherwise = Right . floor . (* 1000) $ posixSeconds
              where posixSeconds = POSIX.utcTimeToPOSIXSeconds t

    -- |Parse a string containing a list of duration measures separated by
    -- spaces. A measure is a non-negative integer followed by a unit (no whitespace is allowed in between).
    -- Every measure is accumulated into a duration. The string is allowed to contain
    -- any number of measures with the same unit in no particular order.
    -- The support units are: days (d), hours (h), minutes (m), seconds (s), milliseconds (ms).
    -- Example: "1d 2h 3m 2d 1h" -> Right 270180000
    textToDuration :: Text -> Either String Word64
    textToDuration t = mapM measureToMs measures >>= Right . sum
      where measures :: [String]
            measures = map Text.unpack . Text.split (== ' ') $ t

            measureToMs :: String -> Either String Word64
            measureToMs m = do
              let (digits, unit) = span Char.isDigit m

              value <- word64FromString digits
              unit' <- case unit of
                "ms" -> Right 1
                "s"  -> Right secInMs
                "m"  -> Right minInMs
                "h"  -> Right hrInMs
                "d"  -> Right dayInMs
                _    -> Left invalidMeasureErrorMsg
              Right $ value * unit'

              where
                invalidMeasureErrorMsg = [iii|"Invalid measure of time '#{m}'.
                                              Should be a non-negative integer followed by a unit (d, h, m, s, ms)."|]

                -- Reading negative numbers directly to Word64 silently underflows, so this approach is necessary.
                word64FromString :: String -> Either String Word64
                word64FromString s = case readMaybe s :: Maybe Integer of
                                      Nothing -> Left invalidMeasureErrorMsg
                                      Just x -> if x >= word64MinBound && x <= word64MaxBound
                                                  then Right . fromIntegral $ x
                                                  else Left invalidMeasureErrorMsg
                  where word64MinBound = 0
                        word64MaxBound = fromIntegral (maxBound :: Word64)



-- |Wrapper for Concordium.Types.Amount that uses a little-endian encoding
-- for binary serialization. Show and JSON instances are inherited from
-- the Amount type.
newtype AmountLE = AmountLE T.Amount
  deriving Eq
  deriving newtype (FromJSON, Show, ToJSON)

instance S.Serialize AmountLE where
  get = S.label "AmountLE" $ AmountLE . T.Amount <$> S.getWord64le
  put (AmountLE T.Amount{..}) = S.putWord64le _amount

-- Time Units

secInMs :: Word64
secInMs = 1000

minInMs :: Word64
minInMs = 60 * secInMs

hrInMs :: Word64
hrInMs = 60 * minInMs

dayInMs :: Word64
dayInMs = 24 * hrInMs
