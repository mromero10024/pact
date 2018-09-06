{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Analyze.Eval where

import           Bound                    (closed)
import           Control.DeepSeq
import           Control.Exception        (ArithException (DivideByZero))
import           Control.Lens             hiding (op, (...))
import           Control.Monad.Catch      (catch)
import           Control.Monad.Except     (runExcept)
import           Control.Monad.IO.Class   (liftIO)
import           Control.Monad.RWS.Strict (runRWST)
import           Data.Aeson               (Value (Object), toJSON)
import qualified Data.Default             as Default
import qualified Data.HashMap.Strict      as HM
import qualified Data.Map.Strict          as Map
import           Data.SBV                 (literal, unliteral, writeArray)
import qualified Data.SBV.Internals       as SBVI
import qualified Data.Text                as T

import           Pact.Analyze.Eval        (lasSucceeds, latticeState,
                                           runAnalyze)
import           Pact.Analyze.Eval.Term   (evalETerm)
import           Pact.Analyze.Types       hiding (Object, Term)
import           Pact.Analyze.Types.Eval  (aeDecimals, aeKeySets, mkAnalyzeEnv,
                                           mkInitialAnalyzeState)
import           Pact.Analyze.Util        (dummyInfo)

import           Pact.Eval                (reduce)
import           Pact.Repl                (initPureEvalEnv)
import           Pact.Repl.Types          (LibState)
import           Pact.Types.Runtime       (EvalEnv, PactError (..),
                                           PactErrorType (EvalError), eeMsgBody,
                                           runEval)
import qualified Pact.Types.Term          as Pact

import           Analyze.Gen

data EvalResult
  = EvalResult !(Pact.Term Pact.Ref)
  | Discard
  | EvalErr !String
  | UnexpectedErr !String

-- Evaluate a term via Pact
pactEval
  :: Pact.Term Pact.Ref
  -> EvalEnv LibState
  -> IO EvalResult
pactEval pactTm evalEnv = (do
    let evalState = Default.def
    -- evaluate via pact, convert to analyze term
    (pactVal, _) <- runEval evalState evalEnv (reduce pactTm)
    Just pactVal' <- pure $ closed pactVal

    -- Fully evaluate (via deepseq) before returning result so we are sure to
    -- catch any exceptions.
    pure $ EvalResult $ show pactVal' `deepseq` pactVal'
  )
    -- discard division by zero, on either the pact or analysis side
    --
    -- future work here is to make sure that if one side throws, the other
    -- does as well.
    `catch` (\(DivideByZero :: ArithException) ->
      pure $ EvalErr "division by zero")
    `catch` (\(pe@(PactError err _ _ msg) :: PactError) ->
      case err of
        EvalError ->
          if "Division by 0" `T.isPrefixOf` msg ||
             "Negative precision not allowed" `T.isPrefixOf` msg
          then pure Discard
          else pure $ EvalErr $ T.unpack msg
        _ -> case msg of
          "(enforce)"     -> pure $ EvalErr $ T.unpack msg
          "(enforce-one)" -> pure $ EvalErr $ T.unpack msg
          ""              -> pure $ UnexpectedErr $ show pe
          _               -> pure $ UnexpectedErr $ T.unpack msg)

-- Evaluate a term symbolically
analyzeEval :: ETerm -> GenState -> IO (Either String ETerm)
analyzeEval etm@(ESimple ty _tm) (GenState _ keysets decimals) = do
  -- analyze setup
  let tables = []
      args = Map.empty
      state0 = mkInitialAnalyzeState tables

      tags = ModelTags Map.empty Map.empty Map.empty Map.empty Map.empty
        -- this 'Located TVal' is never forced so we don't provide it
        (error "analyzeEval: Located TVal unexpectedly forced")
        Map.empty

  Just aEnv <- pure $ mkAnalyzeEnv tables args tags dummyInfo
  -- TODO: also write aeKsAuths
  let writeArray' k v env = writeArray env k v
      aEnv' = foldr (\(k, v) -> aeKeySets
          %~ writeArray' (literal (KeySetName (T.pack k))) (literal v))
        aEnv (Map.toList (fmap snd keysets))
      aEnv'' = foldr
          (\(k, v) -> aeDecimals %~ writeArray' (literal k) (literal v))
        aEnv' (Map.toList decimals)

  -- evaluate via analyze
  (analyzeVal, las) <- case runExcept $ runRWST (runAnalyze (evalETerm etm)) aEnv'' state0 of
    Right (analyzeVal, las, ()) -> pure (analyzeVal, las)
    Left err                    -> error $ describeAnalyzeFailure err

  case unliteral (las ^. latticeState . lasSucceeds . _Wrapped') of
    Nothing -> pure $ Left $ "couldn't unliteral lasSucceeds"
    Just False -> pure $ Left "fails"
    Just True -> case analyzeVal of
      AVal _ sval -> case unliteral (SBVI.SBV sval) of
        Just sval' -> pure $ Right $ ESimple ty $ CoreTerm $ Lit sval'
        Nothing    -> pure $ Left $ "couldn't unliteral: " ++ show sval
      _ -> pure $ Left $ "not AVAl: " ++ show analyzeVal
analyzeEval EObject{} _ = pure (Left "TODO: analyzeEval EObject")

mkEvalEnv :: GenState -> IO (EvalEnv LibState)
mkEvalEnv (GenState _ keysets decimals) = do
  evalEnv <- liftIO initPureEvalEnv
  let keysets' = HM.fromList
        $ fmap (\(k, (pks, _ks)) -> (T.pack k, toJSON pks))
        $ Map.toList keysets
      decimals' = HM.fromList
        $ fmap (\(k, v) -> (T.pack k, toJSON (show (toPact decimalIso v))))
        $ Map.toList decimals
      body = Object $ keysets' `HM.union` decimals'
  pure $ evalEnv & eeMsgBody .~ body
