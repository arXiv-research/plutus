-- editorconfig-checker-disable-file
{-| Description : Property based testing for Plutus Core

This file contains the tests and some associated machinery but not the
generators.
-}

{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE RecordWildCards       #-}

module PlutusCore.Generators.NEAT.Spec
  ( tests
  , GenOptions (..)
  , defaultGenOptions
  , Options (..)
  , TestFail (..)
  , testCaseGen
  , bigTest
  , packAssertion
  , tynames
  , names
  , throwCtrex
  , Ctrex (..)
  , handleError
  , handleUError
  ) where

import PlutusCore
import PlutusCore.Compiler.Erase
import PlutusCore.Evaluation.Machine.Ck
import PlutusCore.Evaluation.Machine.ExBudgetingDefaults
import PlutusCore.Generators.NEAT.Common
import PlutusCore.Generators.NEAT.Term
import PlutusCore.Normalize
import PlutusCore.Pretty

import UntypedPlutusCore qualified as U
import UntypedPlutusCore.Evaluation.Machine.Cek qualified as U

import Control.Monad.Except
import Control.Search (Enumerable (..), Options (..), ctrex', search')
import Data.Coolean (Cool, toCool, (!=>))
import Data.Either
import Data.Maybe
import Data.Stream qualified as Stream
import Data.Text qualified as Text
import System.IO.Unsafe
import Test.Tasty
import Test.Tasty.HUnit
import Text.Printf

-- * Property-based tests

data GenOptions = GenOptions
  { genDepth :: Int     -- ^ Search depth, measured in program size
  , genMode  :: Options -- ^ Search strategy
  }

defaultGenOptions :: GenOptions
defaultGenOptions = GenOptions
  { genDepth = 11
  , genMode  = OF
  }

tests :: GenOptions -> TestTree
tests genOpts@GenOptions{} =
  testGroup "NEAT"

  [ bigTest "normalization commutes with conversion from generated types"
      genOpts {genDepth = 13}
      (Type ())
      (packAssertion prop_normalizeConvertCommuteTypes)
  , bigTest "normal types cannot reduce"
      genOpts {genDepth = 14}
      (Type ())
      (packAssertion prop_normalTypesCannotReduce)
  , bigTest "type preservation - CK"
      genOpts {genDepth = 18}
      (TyBuiltinG TyUnitG)
      (packAssertion prop_typePreservation)
  , bigTest "typed CK vs untyped CEK produce the same output"
      genOpts {genDepth = 18}
      (TyBuiltinG TyUnitG)
      (packAssertion prop_agree_termEval)
  ]


{- NOTE:

The tests below perform multiple steps in a pipeline, they take in
kind & type or type & term and then peform operations on them passing
the result along to the next one, sometimes the result is passed to
several operations and/or several results are later combined and
sometimes a result is discarded. Quite a lot of this is inherently
sequential. There is some limited opportunity for parallelism which is
not exploited.

-}

-- handle a user error and turn it back into an error term
handleError :: Type TyName DefaultUni ()
       -> U.ErrorWithCause (U.EvaluationError user internal) term
       -> Either (U.ErrorWithCause (U.EvaluationError user internal) term)
                 (Term TyName Name DefaultUni DefaultFun ())
handleError ty e = case U._ewcError e of
  U.UserEvaluationError     _ -> return (Error () ty)
  U.InternalEvaluationError _ -> throwError e

-- untyped version of `handleError`
handleUError ::
          U.ErrorWithCause (U.EvaluationError user internal) term
       -> Either (U.ErrorWithCause (U.EvaluationError user internal) term)
                 (U.Term Name DefaultUni DefaultFun ())
handleUError e = case U._ewcError e of
  U.UserEvaluationError     _ -> return (U.Error ())
  U.InternalEvaluationError _ -> throwError e

-- |Property: check if the type is preserved by evaluation.
--
-- This property is expected to hold for the CK machine.
--
prop_typePreservation :: ClosedTypeG -> ClosedTermG -> ExceptT TestFail Quote ()
prop_typePreservation tyG tmG = do
  tcConfig <- withExceptT TypeError $ getDefTypeCheckConfig ()

  -- Check if the type checker for generated terms is sound:
  ty <- withExceptT GenError $ convertClosedType tynames (Type ()) tyG
  withExceptT TypeError $ checkKind () ty (Type ())
  tm <- withExceptT GenError $ convertClosedTerm tynames names tyG tmG
  withExceptT TypeError $ checkType tcConfig () tm (Normalized ty)

  -- Check if the converted term, when evaluated by CK, still has the same type:

  tmCK <- withExceptT CkP $ liftEither $
    evaluateCkNoEmit defaultBuiltinsRuntime tm `catchError` handleError ty
  withExceptT TypeError $ checkType tcConfig () tmCK (Normalized ty)

-- |Property: check if both the typed CK and untyped CEK machines produce the same ouput
-- modulo erasure.
--
prop_agree_termEval :: ClosedTypeG -> ClosedTermG -> ExceptT TestFail Quote ()
prop_agree_termEval tyG tmG = do
  tcConfig <- withExceptT TypeError $ getDefTypeCheckConfig ()

  -- Check if the type checker for generated terms is sound:
  ty <- withExceptT GenError $ convertClosedType tynames (Type ()) tyG
  withExceptT TypeError $ checkKind () ty (Type ())
  tm <- withExceptT GenError $ convertClosedTerm tynames names tyG tmG
  withExceptT TypeError $ checkType tcConfig () tm (Normalized ty)

  -- run typed CK on input
  tmCk <- withExceptT CkP $ liftEither $
    evaluateCkNoEmit defaultBuiltinsRuntime tm `catchError` handleError ty

  -- erase CK output
  let tmUCk = eraseTerm tmCk

  -- run untyped CEK on erased input
  tmUCek <- withExceptT UCekP $ liftEither $
    U.evaluateCekNoEmit defaultCekParameters (eraseTerm tm) `catchError` handleUError

  -- check if typed CK and untyped CEK give the same output modulo erasure
  unless (tmUCk == tmUCek) $
    throwCtrex (CtrexUntypedTermEvaluationMismatch tyG tmG [("untyped CK",tmUCk),("untyped CEK",tmUCek)])

-- |Property: the following diagram commutes for well-kinded types...
--
-- @
--                  convertClosedType
--    ClosedTypeG ---------------------> Type TyName DefaultUni ()
--         |                                        |
--         |                                        |
--         | normalizeTypeG                         | normalizeType
--         |                                        |
--         v                                        v
--    ClosedTypeG ---------------------> Type TyName DefaultUni ()
--                  convertClosedType
-- @
--
prop_normalizeConvertCommuteTypes :: Kind ()
                                  -> ClosedTypeG
                                  -> ExceptT TestFail Quote ()
prop_normalizeConvertCommuteTypes k tyG = do
  -- Check if the kind checker for generated types is sound:
  ty <- withExceptT GenError $ convertClosedType tynames k tyG
  withExceptT TypeError $ checkKind () ty k

  -- Check if the converted type, when reduced, still has the same kind:
  ty1 <- withExceptT TypeError $ unNormalized <$> normalizeType ty
  withExceptT TypeError $ checkKind () ty k

  -- Check if normalization for generated types is sound:
  ty2 <- withExceptT GenError $ convertClosedType tynames k (normalizeTypeG tyG)

  unless (ty1 == ty2) $
    throwCtrex (CtrexNormalizeConvertCommuteTypes k tyG ty1 ty2)



-- |Property: normal types cannot reduce
prop_normalTypesCannotReduce :: Kind ()
                             -> Normalized ClosedTypeG
                             -> ExceptT TestFail Quote ()
prop_normalTypesCannotReduce k (Normalized tyG) =
  unless (isNothing $ stepTypeG tyG) $
    throwCtrex (CtrexNormalTypesCannotReduce k tyG)

-- |Create a generator test, searching for a counter-example to the
-- given predicate.

-- NOTE: we are not currently using this approach (using `ctrex'` to
-- search for a counter example), instead we generate a list of
-- examples using `search'` and look for a counter example ourselves
testCaseGen :: (Check t a, Enumerable a, Show e)
        => TestName
        -> GenOptions
        -> t
        -> (t -> a -> ExceptT e Quote ())
        -> TestTree
testCaseGen name GenOptions{..} t prop =
  testCaseInfo name $ do
    -- NOTE: in the `Right` case, `prop t ctrex` is guarded by `not
    -- (isOk (prop t ctrex))` hence the reasonable use of undefined
    result <- ctrex' genMode genDepth (\x -> check t x !=> isOk (prop t x))
    case result of
      Left  count -> return $ printf "%d examples generated" count
      Right ctrex ->
        assertFailure . show . fromLeft undefined . run $ prop t ctrex


-- * Test failures

-- NOTE: a test may fail for several reasons:
--       - we encounter an error in the generator;
--       - we encounter an error while type checking Plutus terms;
--       - we encounter an error while converting to deBruijn notation;
--       - we encounter an error while running the Agda terms;
--       - we found a counter-example.
--
-- This is distinction is not strictly enforced as ultimately
-- everything leads to a counter-example of some kind

data TestFail
  = GenError GenError
  | TypeError
    (TypeError
      (Term TyName Name DefaultUni DefaultFun ())
      DefaultUni
      DefaultFun
      ())
  | AgdaErrorP ()
  | FVErrorP FreeVariableError
  | CkP (CkEvaluationException DefaultUni DefaultFun)
  | UCekP (U.CekEvaluationException Name DefaultUni DefaultFun)
  | Ctrex Ctrex

data Ctrex
  = CtrexNormalizeConvertCommuteTypes
    (Kind ())
    ClosedTypeG
    (Type TyName DefaultUni ())
    (Type TyName DefaultUni ())
  | CtrexNormalTypesCannotReduce
    (Kind ())
    ClosedTypeG
  | CtrexKindCheckFail
    (Kind ())
    ClosedTypeG
  | CtrexKindPreservationFail
    (Kind ())
    ClosedTypeG
  | CtrexKindMismatch
    (Kind ())
    ClosedTypeG
    (Kind ())
    (Kind ())
  | CtrexTypeNormalizationFail
    (Kind ())
    ClosedTypeG
  | CtrexTypeNormalizationMismatch
    (Kind ())
    ClosedTypeG
    (Type TyName DefaultUni ())
    (Type TyName DefaultUni ())
  | CtrexTypeCheckFail
    ClosedTypeG
    ClosedTermG
  | CtrexTypePreservationFail
    ClosedTypeG
    ClosedTermG
    (Term TyName Name DefaultUni DefaultFun ())
    (Term TyName Name DefaultUni DefaultFun ())
  | CtrexTermEvaluationFail
    String
    ClosedTypeG
    ClosedTermG
  | CtrexTermEvaluationMismatch
    ClosedTypeG
    ClosedTermG
    [(String,Term TyName Name DefaultUni DefaultFun ())]
  | CtrexUntypedTermEvaluationMismatch
    ClosedTypeG
    ClosedTermG
    [(String,U.Term Name DefaultUni DefaultFun ())]

instance Show TestFail where
  show (TypeError e)  = "type error: " ++ show e
  show (GenError e)   = "generator error: " ++ show e
  show (Ctrex e)      = "counter example error: " ++ show e
  show (AgdaErrorP e) = "agda error: " ++ show e
  show (FVErrorP e)   = "free variable error: " ++ show e
  show (CkP e)        = "CK error: " ++ show e
  show (UCekP e)      = "UCEK error: " ++ show e

instance Show Ctrex where
  show (CtrexNormalizeConvertCommuteTypes k tyG ty1 ty2) =
    printf
      tpl
      (show tyG)
      (show (pretty k))
      (show (pretty ty1))
      (show (pretty ty2))
    where
      tpl = unlines
            [ "Counterexample found: %s :: %s"
            , "- convert then normalize gives %s"
            , "- normalize then convert gives %s"
            ]

  show (CtrexNormalTypesCannotReduce k tyG) =
    printf tpl (show tyG) (show (pretty k))
    where
      tpl = "Counterexample found: normal type %s of kind %s can reduce."

  show (CtrexKindCheckFail k tyG) =
    printf tpl (show tyG) (show (pretty k))
    where
      tpl = "Counterexample found (kind check fail): %s :: %s"
  show (CtrexKindPreservationFail k tyG) =
    printf tpl (show tyG) (show (pretty k))
    where
      tpl = "Counterexample found (kind preservation fail): %s :: %s"
  show (CtrexKindMismatch k tyG k' k'') =
    printf
      tpl
      (show (pretty k))
      (show tyG)
      (show (pretty k'))
      (show (pretty k''))
    where
      tpl = unlines
            [ "Counterexample found: %s :: %s"
            , "- inferer1 gives %s"
            , "- inferer2 gives %s"
            ]
  show (CtrexTypeNormalizationFail k tyG) =
    printf tpl (show tyG) (show (pretty k))
    where
      tpl = "Counterexample found (type normalisation fail): %s :: %s"
  show (CtrexTypeNormalizationMismatch k tyG ty1 ty2) =
    printf
      tpl
      (show tyG)
      (show (pretty k))
      (show (pretty ty1))
      (show (pretty ty2))
    where
      tpl = unlines
            [ "Counterexample found: %s :: %s"
            , "- normalizer1 gives %s"
            , "- normalizer2 gives %s"
            ]
  show (CtrexTypeCheckFail tyG tmG) =
    printf tpl (show tmG) (show tyG)
    where
      tpl = "Counterexample found (typecheck fail): %s :: %s"
  show (CtrexTermEvaluationFail s tyG tmG) =
    printf tpl (show tmG) (show tyG)
    where
      tpl = "Counterexample found (" ++ s ++ " term evaluation fail): %s :: %s"
  show (CtrexTermEvaluationMismatch tyG tmG tms) =
    printf tpl (show tmG) (show tyG) ++ results tms
    where
      tpl = "TypedTermEvaluationMismatch\n" ++ "Counterexample found: %s :: %s\n"
      results ((s,t):ts) = s ++ " evaluation: " ++ show (pretty t) ++ "\n" ++ results ts
      results []         = ""
  show (CtrexUntypedTermEvaluationMismatch tyG tmG tms) =
    printf tpl (show tmG) (show tyG) ++ results tms
    where
      tpl = "UntypedTermEvaluationMismatch\n" ++ "Counterexample found: %s :: %s\n"
      results ((s,t):ts) = s ++ " evaluation: " ++ show (pretty t) ++ "\n" ++ results ts
      results []         = ""
  show (CtrexTypePreservationFail tyG tmG tm1 tm2) =
    printf tpl (show tmG) (show tyG) (show (pretty tm1)) (show (pretty tm2))
    where
      tpl = unlines
            [ "Counterexample found: %s :: %s"
            , "before evaluation: %s"
            , "after evaluation:  %s"
            ]

-- | Throw a counter-example.
throwCtrex :: Ctrex -> ExceptT TestFail Quote ()
throwCtrex ctrex = throwError (Ctrex ctrex)

-- |Check if running |Quote| and |Except| throws any errors.
isOk :: ExceptT e Quote a -> Cool
isOk = toCool . isRight . run

-- |Run |Quote| and |Except| effects.
run :: ExceptT e Quote a -> Either e a
run = runQuote . runExceptT

-- |Stream of type names t0, t1, t2, ..
tynames :: Stream.Stream Text.Text
tynames = mkTextNameStream "t"

-- |Stream of names x0, x1, x2, ..
names :: Stream.Stream Text.Text
names = mkTextNameStream "x"

-- given a prop, generate examples and then turn them into individual
-- tasty tests. This can be accomplished without unsafePerformIO but
-- this is convenient to use.
-- e.g., add this to the tesGroup "NEAT" list above:
{-
  mapTest
      genOpts {genDepth = 13}
      (Type ())
      (packTest prop_normalizeConvertCommuteTypes)
-}

_mapTest :: (Check t a, Enumerable a)
        => GenOptions -> t -> (t -> a -> TestTree) -> TestTree
_mapTest GenOptions{..} t f = testGroup "a bunch of tests" $ map (f t) examples
  where
  examples = unsafePerformIO $ search' genMode genDepth (\a -> check t a)

-- | given a prop, generate one test
packAssertion :: (Show e) => (t -> a -> ExceptT e Quote ()) -> t -> a -> Assertion
packAssertion f t a =
  case (runQuote . runExceptT $ f t a) of
    Left  e -> assertFailure $ show e
    Right _ -> return ()

-- | generate examples using `search'` and then generate one big test
-- that applies the given test to each of them.

bigTest :: (Check t a, Enumerable a)
        => String -> GenOptions -> t -> (t -> a -> Assertion) -> TestTree
bigTest s GenOptions{..} t f = testCaseInfo s $ do
  as <- search' genMode genDepth (\a ->  check t a)
  _  <- traverse (f t) as
  return $ show (length as)
