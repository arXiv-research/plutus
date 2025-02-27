-- editorconfig-checker-disable-file
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module PlutusCore.Evaluation.Machine.CostModelInterface
    ( CostModelParams
    , CekMachineCosts
    , extractCostModelParams
    , applyCostModelParams
    , CostModelApplyError (..)
    )
where

import PlutusCore.Evaluation.Machine.BuiltinCostModel ()
import PlutusCore.Evaluation.Machine.MachineParameters (CostModel (..))
import UntypedPlutusCore.Evaluation.Machine.Cek.CekMachineCosts (CekMachineCosts, cekMachineCostsPrefix)

import Control.Exception
import Control.Monad.Except
import Data.Aeson
import Data.Aeson.Flatten
import Data.HashMap.Strict qualified as HM
import Data.Map qualified as Map
import Data.Map.Merge.Lazy qualified as Map
import Data.Text qualified as Text
import Prettyprinter

{- Note [Cost model parameters]
We want to expose to the ledger some notion of the "cost model
parameters". Intuitively, these should be all the numbers that appear in the
cost model.

However, there are quite a few quirks to deal with.

1. BuiltinCostModel is stuctured.

That is, it's a complex data structure and the numbers in question are often
nested inside it.  To deal with this quickly, we take the ugly approach of
operating on the JSON representation of the model.  We flatten this down into a
simple key-value mapping (see 'flattenObject' and 'unflattenObject'), and then
look only at the numbers.

2. We use CostingIntegers, Aeson uses Data.Scientific.

The numbers in CostModel objects are CostingIntegers, which are usually the
64-bit SatInt type (but Integer on 32-bit machines).  Numerical values in
Aeson-encoded JSON objects are represented as Data.Scientific (Integer mantissa,
Int exponent). We should be able to convert between these types without loss of
precision, except that Scientific numbers of large magnitude will overflow to
SatInt::MaxBound or underflow to SatInt::MinBound.  This is OK because
CostModelParams objects should never contain such large numbers. Any Plutus Core
programs whose cost reaches MaxBound will fail due to excessive resource usage.

3. BuiltinCostModel includes the *type* of the model, which isn't a parameter

We can just strip the type out, but in particular this means that the parameters are
not enough to *construct* a model.  So we punt and say that you can *update* a
model by giving the parameters. So you can take the default model and then
overwrite the parameters, which seems okay.

This is also implemented in a horrible JSON-y way.

4. The implementation is not nice.

Ugly JSON stuff and failure possibilities where there probably shouldn't be any.

5. The overall cost model now includes two components: a model for the internal
costs of the evaluator and a model for built-in evaluation costs.  We just
re-use the technique mentioned above to extract parameters for the evaluator
costs, merging these with the parameters for the builtin cost model to obtain
parameters for the overall model.  To recover cost model components we assume
that every field in the cost model for the evaluator begins with a prefix (eg
"cek") which is does not occur as a prefix of any built-in function, and use
that to split the map of parameters into two maps.

-}

-- See Note [Cost model parameters]
type CostModelParams = Map.Map Text.Text Integer

-- See Note [Cost model parameters]
-- | Extract the model parameters from a model.
extractParams :: ToJSON a => a -> Maybe CostModelParams
extractParams cm = case toJSON cm of
    Object o ->
        let
            flattened = objToHm $ flattenObject "-" o
            usingCostingIntegers = HM.mapMaybe (\case { Number n -> Just $ ceiling n; _ -> Nothing }) flattened
            -- ^ Only (the contents of) the "Just" values are retained in the output map.
            mapified = Map.fromList $ HM.toList usingCostingIntegers
        in Just mapified
    _ -> Nothing


-- | The type of errors that 'applyParams' can throw.
data CostModelApplyError =
      CMUnknownParamError Text.Text
      -- ^ a costmodel parameter with the give name does not exist in the costmodel to be applied upon
    | CMInternalReadError
      -- ^ internal error when we are transforming the applyParams' input to json (should not happen)
    | CMInternalWriteError String
      -- ^ internal error when we are transforming the applied params from json with given jsonstring error (should not happen)
    | CMWrongNumberOfParams Int Int
      -- ^ the ledger is supposed to pass the full list of params, no more, no less params.
    deriving stock Show
    deriving anyclass Exception

instance Pretty CostModelApplyError where
    pretty = (preamble <+>) . \case
        CMUnknownParamError k -> "Unknown cost model parameter:" <+> pretty k
        CMInternalReadError      -> "Internal problem occurred upon reading the given cost model parameteres"
        CMInternalWriteError str     -> "Internal problem occurred upon generating the applied cost model parameters with JSON error:" <+> pretty str
        CMWrongNumberOfParams expected actual     -> "Wrong number of cost model parameters passed, expected" <+> pretty expected <+> "but got" <+> pretty actual
      where
          preamble = "applyParams error:"

-- See Note [Cost model parameters]
-- | Update a model by overwriting the parameters with the given ones.
applyParams :: (FromJSON a, ToJSON a, MonadError CostModelApplyError m)
            => a
            -> CostModelParams
            -> m a
applyParams cm params = case toJSON cm of
    Object o ->
        let
            usingScientific = fmap (Number . fromIntegral) params
            flattened = fromHash $ objToHm $ flattenObject "-" o
        in do
            -- this is where the overwriting happens
            -- fail when key is in params (left) but not in the model (right)
            merged <- Map.mergeA failMissing Map.preserveMissing (Map.zipWithMatched leftBiased) usingScientific flattened
            let unflattened = unflattenObject "-" $ hmToObj $ toHash merged
            case fromJSON (Object unflattened) of
                Success a -> pure a
                Error str -> throwError $ CMInternalWriteError str
    _ -> throwError CMInternalReadError
  where
    toHash = HM.fromList . Map.toList
    fromHash = Map.fromList . HM.toList
    -- fail when field missing
    failMissing = Map.traverseMissing $ \ k _v -> throwError $ CMUnknownParamError k
    -- left-biased merging when key found in both maps
    leftBiased _k l _r = l


-- | Parameters for a machine step model and a builtin evaluation model bundled together.
data SplitCostModelParams =
    SplitCostModelParams {
      _machineParams :: CostModelParams
    , _builtinParams :: CostModelParams
    }

-- | Split a CostModelParams object into two subobjects according to some prefix:
-- see item 5 of Note [Cost model parameters].
splitParams :: Text.Text -> CostModelParams -> SplitCostModelParams
splitParams prefix params =
    let (machineparams, builtinparams) = Map.partitionWithKey (\k _ -> Text.isPrefixOf prefix k) params
    in SplitCostModelParams machineparams builtinparams

-- | Given a CostModel, produce a single map containing the parameters from both components
extractCostModelParams
    :: (ToJSON machinecosts, ToJSON builtincosts)
    => CostModel machinecosts builtincosts -> Maybe CostModelParams
extractCostModelParams model = -- this is using the applicative instance of Maybe
    Map.union <$> extractParams (_machineCostModel model) <*> extractParams (_builtinCostModel model)

-- | Given a set of cost model parameters, split it into two parts according to
-- some prefix and use those parts to update the components of a cost model.
{- Strictly we don't need to do the splitting: when we call fromJSON in
   applyParams any superfluous objects in the map being decoded will be
   discarded, so we could update both components of the cost model with the
   entire set of parameters without having to worry about splitting the
   parameters on a prefix of the key.  This relies on what appears to be an
   undocumented implementation choice in Aeson though (other JSON decoders (for
   other languages) seem to vary in how unknown fields are handled), so let's be
   explicit. -}
applySplitCostModelParams
    :: (FromJSON evaluatorcosts, FromJSON builtincosts, ToJSON evaluatorcosts, ToJSON builtincosts, MonadError CostModelApplyError m)
    => Text.Text
    -> CostModel evaluatorcosts builtincosts
    -> CostModelParams
    -> m (CostModel evaluatorcosts builtincosts)
applySplitCostModelParams prefix model params =
    let SplitCostModelParams machineparams builtinparams = splitParams prefix params
    in CostModel <$> applyParams (_machineCostModel model) machineparams
                 <*> applyParams (_builtinCostModel model) builtinparams

-- | Update a CostModel for the CEK machine with a given set of parameters,
applyCostModelParams
    :: (FromJSON evaluatorcosts, FromJSON builtincosts, ToJSON evaluatorcosts, ToJSON builtincosts, MonadError CostModelApplyError m)
    => CostModel evaluatorcosts builtincosts
    -> CostModelParams
    -> m (CostModel evaluatorcosts builtincosts)
applyCostModelParams = applySplitCostModelParams cekMachineCostsPrefix
