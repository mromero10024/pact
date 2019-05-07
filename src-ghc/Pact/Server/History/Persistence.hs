{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Pact.Server.History.Persistence
  ( createDB
  , insertCompletedCommand
  , queryForExisting
  , selectCompletedCommands
  , selectAllCommands
  , closeDB
  ) where


import Control.Monad

import qualified Data.Text as T
import qualified Data.Aeson as A
import Data.Text.Encoding (encodeUtf8)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BSL

import Data.List (sortBy)
import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.Maybe

import Database.SQLite3.Direct

import Pact.Types.Command
import Pact.Types.Runtime
import Pact.Types.SQLite

import Pact.Server.History.Types



--- SQL DATABASE CREATION AND DELETION ---

createDB :: FilePath -> IO DbEnv
createDB f = do
  conn' <- eitherToError "OpenDB" <$> open (Utf8 $ encodeUtf8 $ T.pack f)
  eitherToError "CreateTable" <$> exec conn' sqlDbSchema
--  eitherToError "pragmas" <$> exec conn "PRAGMA locking_mode = EXCLUSIVE"
  DbEnv <$> pure conn'
        <*> prepStmt conn' sqlInsertHistoryRow
        <*> prepStmt conn' sqlQueryForExisting
        <*> prepStmt conn' sqlSelectCompletedCommands
        <*> prepStmt conn' sqlSelectAllCommands

closeDB :: DbEnv -> IO ()
closeDB DbEnv{..} = do
  liftEither $ closeStmt _insertStatement
  liftEither $ closeStmt _qryExistingStmt
  liftEither $ closeStmt _qryCompletedStmt
  liftEither $ closeStmt _qrySelectAllCmds
  liftEither $ close _conn



--- SQL STATEMENTS ---

sqlDbSchema :: Utf8
sqlDbSchema =
  "CREATE TABLE IF NOT EXISTS 'main'.'pactCommands' \
  \( 'hash' TEXT PRIMARY KEY NOT NULL UNIQUE\
  \, 'txid' INTEGER NOT NULL\
  \, 'command' TEXT NOT NULL\
  \, 'result' TEXT NOT NULL\
  \, 'userSigs' TEXT NOT NULL\
  \, 'gas' INTEGER NOT NULL\
  \, 'logs' TEXT NOT NULL\
  \, 'continuation' TEXT NOT NULL\
  \, 'metadata' TEXT NOT NULL\
  \)"

sqlInsertHistoryRow :: Utf8
sqlInsertHistoryRow =
    "INSERT INTO 'main'.'pactCommands' \
    \( 'hash'\
    \, 'txid' \
    \, 'command'\
    \, 'result'\
    \, 'userSigs'\
    \, 'gas'\
    \, 'logs'\
    \, 'continuation'\
    \, 'metadata'\
    \) VALUES (?,?,?,?,?,?,?,?,?)"

sqlQueryForExisting :: Utf8
sqlQueryForExisting = "SELECT EXISTS(SELECT 1 FROM 'main'.'pactCommands' WHERE hash=:hash LIMIT 1)"

sqlSelectCompletedCommands :: Utf8
sqlSelectCompletedCommands =
  "SELECT result,txid,gas,logs,continuation,metadata FROM 'main'.'pactCommands' WHERE hash=:hash LIMIT 1"

sqlSelectAllCommands :: Utf8
sqlSelectAllCommands = "SELECT hash,command,userSigs FROM 'main'.'pactCommands' ORDER BY txid ASC"



--- SQL STATEMENT USAGE ---

insertCompletedCommand :: DbEnv -> [(Command ByteString, (CommandResult Hash))] -> IO ()
insertCompletedCommand DbEnv{..} v = do
  let sortCmds (_,cr1) (_,cr2) = compare (_crTxId cr1) (_crTxId cr2)
  eitherToError "start insert transaction" <$> exec _conn "BEGIN TRANSACTION"
  mapM_ (insertRow _insertStatement) $ sortBy sortCmds v
  eitherToError "end insert transaction" <$> exec _conn "END TRANSACTION"

insertRow :: Statement -> (Command ByteString, (CommandResult Hash)) -> IO ()
insertRow s (Command{..},CommandResult {..}) =
    execs s [toTextField (toUntypedHash _cmdHash)
            ,SInt $ fromIntegral (fromMaybe (-1) _crTxId)
            ,SText $ Utf8 _cmdPayload
            ,toTextField _crResult
            ,toTextField _cmdSigs
            ,SInt $ fromIntegral _crGas
            ,toTextField _crLogs
            ,toTextField _crContinuation
            ,toTextField _crMetaData]


queryForExisting :: DbEnv -> HashSet RequestKey -> IO (HashSet RequestKey)
queryForExisting e v = foldM f v v
  where
    f s rk = do
      r <- qrys (_qryExistingStmt e) [toTextField $ unRequestKey rk] [RInt]
      case r of
        [[SInt 1]] -> return s
        _ -> return $ HashSet.delete rk s


selectCompletedCommands :: DbEnv -> HashSet RequestKey -> IO (HashMap RequestKey (CommandResult Hash))
selectCompletedCommands e v = foldM f HashMap.empty v
  where
    f m rk = do
      rs <- qrys (_qryCompletedStmt e) [toTextField $ unRequestKey rk] [RText,RInt,RInt,RText,RText,RText]
      if null rs
      then return m
      else case head rs of
          [SText (Utf8 cr),
           SInt tid,
           SInt g,
           SText (Utf8 l),
           SText (Utf8 ct),
           SText (Utf8 md)] ->
            return $ HashMap.insert rk
            (CommandResult rk
                           (if tid < 0 then Nothing else Just (fromIntegral tid))
                           (crFromField cr)
                           (Gas g)
                           (Just $ logsFromField l)
                           (contFromField ct)
                           (metaFromField md)
            ) m
          r -> dbError $ "Invalid result from query: " ++ show r


selectAllCommands :: DbEnv -> IO [Command ByteString]
selectAllCommands e = do
  let rowToCmd [SText (Utf8 hash'),SText (Utf8 cmd'),SText (Utf8 userSigs')] =
              Command { _cmdPayload = cmd'
                      , _cmdSigs = userSigsFromField userSigs'
                      , _cmdHash = fromUntypedHash $ hashFromField hash'}
      rowToCmd err = error $ "selectAllCommands: unexpected result schema: " ++ show err
  fmap rowToCmd <$> qrys_ (_qrySelectAllCmds e) [RText,RText,RText]



--- UTILS ---

toTextField :: (A.ToJSON a) => a -> SType
toTextField r = SText $ Utf8 $ BSL.toStrict $ A.encode r

hashFromField :: ByteString -> Hash
hashFromField h = case A.eitherDecodeStrict' h of
  Left err -> error $ "hashFromField: unable to decode Hash from database! " ++ show err ++ " => " ++ show h
  Right v -> v

userSigsFromField :: ByteString -> [UserSig]
userSigsFromField us = case A.eitherDecodeStrict' us of
  Left err -> error $ "userSigsFromField: unable to decode [UserSigs] from database! " ++ show err ++ "\n" ++ show us
  Right v -> v

crFromField :: ByteString -> PactResult
crFromField = undefined

logsFromField :: ByteString -> Hash
logsFromField = undefined

contFromField :: ByteString -> Maybe PactExec
contFromField a = undefined

metaFromField :: ByteString -> Maybe A.Value
metaFromField = undefined


eitherToError :: Show e => String -> Either e a -> a
eitherToError _ (Right v) = v
eitherToError s (Left e) = error $ "SQLite Error in History exec: " ++ s ++ "\nWith Error: "++ show e

















