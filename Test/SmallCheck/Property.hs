-- vim:fdm=marker:foldtext=foldtext()

--------------------------------------------------------------------
-- |
-- Module    : Test.SmallCheck.Property
-- Copyright : (c) Colin Runciman et al.
-- License   : BSD3
-- Maintainer: Roman Cheplyaka <roma@ro-che.info>
--
-- Properties and tools to construct them.
--------------------------------------------------------------------
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, TypeFamilies,
             ScopedTypeVariables #-}
module Test.SmallCheck.Property (
  -- * Quantifiers
  forAll, exists, existsUnique, over, (==>), monadic, property,

  -- * Property's entrails
  Property,

  PropertySuccess(..), PropertyFailure(..), runProperty, TestQuality(..), Argument, Depth, Testable(..),
  ) where

import Test.SmallCheck.Series
import Test.SmallCheck.SeriesMonad
import Control.Monad
import Control.Monad.Logic
import Control.Monad.Reader
import Control.Applicative
import Data.Typeable

------------------------------
-- Property-related types
------------------------------
--{{{

newtype Property m = Property { unProperty :: Reader (Env m) (PropertySeries m) }

data PropertySeries m =
  PropertySeries
    { searchExamples        :: Series m PropertySuccess
    , searchCounterExamples :: Series m PropertyFailure
    , searchClosest         :: Series m (Property m, [Argument])
    }

data Env m =
  Env
    { quantification :: Quantification
    , testHook :: TestQuality -> m ()
    }

data Quantification
  = Forall
  | Exists
  | ExistsUnique

data TestQuality
  = GoodTest
  | BadTest
  deriving (Eq, Ord, Enum, Show)

type Argument = String

data PropertySuccess
  = Exist [Argument] PropertySuccess
  | ExistUnique [Argument] PropertySuccess
  | PropertyTrue
  | Vacuously PropertyFailure
  deriving (Eq, Show)

data PropertyFailure
  = NotExist
  | AtLeastTwo [Argument] PropertySuccess [Argument] PropertySuccess
  | CounterExample [Argument] PropertyFailure
  | PropertyFalse
  deriving (Eq, Show)

instance Typeable1 m => Typeable (Property m)
  where
    typeOf _ =
      mkTyConApp
        (mkTyCon3 "smallcheck" "Test.SmallCheck.Property" "Property")
        [typeOf (undefined :: m ())]

-- }}}

------------------------------------
-- Property runners and constructors
------------------------------------
--{{{

unProp q (Property p) = runReader p q

runProperty
  :: Monad m
  => Depth
  -> (TestQuality -> m ())
  -> Property m
  -> m (Maybe PropertyFailure)
runProperty depth hook prop =
  (\l -> runLogicT l (\x _ -> return $ Just x) (return Nothing)) $
  runSeries depth $
  searchCounterExamples $
  flip runReader (Env Forall hook) $
  unProperty prop

atomicProperty :: Series m PropertySuccess -> Series m PropertyFailure -> PropertySeries m
atomicProperty s f =
  let prop = PropertySeries s f (pure (Property $ pure prop, []))
  in prop

makeAtomic :: Property m -> Property m
makeAtomic (Property prop) =
  Property $ flip fmap prop $ \ps ->
    atomicProperty (searchExamples ps) (searchCounterExamples ps)

-- | @'over' s $ \\x -> p x@ makes @x@ range over the 'Series' @s@ (by
-- default, all variables range over the 'series' for their types).
--
-- Note that, unlike the quantification operators, this affects only the
-- variable following the operator and not subsequent variables.
--
-- 'over' does not affect the quantification context.
over
  :: (Monad m, Show a, Testable m b)
  => Series m a -> (a -> b) -> Property m
over = testFunction

-- | Execute a monadic test
monadic :: Testable m a => m a -> Property m
monadic a =
  Property $ reader $ \env ->

    let pair = unProp env . freshContext <$> lift a in

    atomicProperty
      (searchExamples =<< pair)
      (searchCounterExamples =<< pair)

-- | Wrap an arbitrary 'Testable' into a 'Property'.
property :: Testable m a => a -> Property m
property = test

-- }}}

-------------------------------
-- Testable class and instances
-------------------------------
-- {{{

-- | Class of tests that can be run in a monad. For pure tests, it is
-- recommended to keep their types polymorphic in @m@ rather than
-- specialising it to 'Identity'.
class Monad m => Testable m a where
  test :: a -> Property m

instance Monad m => Testable m Bool where
  test b = Property $ reader $ \env ->
    let
      success = do
        lift $ testHook env GoodTest
        if b then return PropertyTrue else mzero
      failure = PropertyFalse <$ lnot success
    in atomicProperty success failure

instance (Serial m a, Show a, Testable m b) => Testable m (a->b) where
  test = testFunction series

instance (Monad m, m ~ n) => Testable n (Property m) where
  test = id

testFunction
  :: (Monad m, Show a, Testable m b)
  => Series m a -> (a -> b) -> Property m
testFunction s f = Property $ reader $ \env ->
  let
    closest = do
      x <- s
      (p, args) <- searchClosest $ unProp env $ test $ f x
      return (p, show x : args)
  in

  case quantification env of
    Forall -> PropertySeries success failure closest
      -- {{{
      where
        failure = do
          x <- s
          failure <- searchCounterExamples $ unProp env $ test $ f x
          let arg = show x
          return $
            case failure of
              CounterExample args etc -> CounterExample (arg:args) etc
              _ -> CounterExample [arg] failure

        success = PropertyTrue <$ lnot failure
      -- }}}

    Exists -> PropertySeries success failure closest
      -- {{{
      where
        success = do
          x <- s
          s <- searchExamples $ unProp env $ test $ f x
          let arg = show x

          return $
            case s of
              Exist args etc -> Exist (arg:args) etc
              _ -> Exist [arg] s

        failure = NotExist <$ lnot success
      -- }}}

    ExistsUnique -> PropertySeries success failure closest
      -- {{{
      where
        search = atMost 2 $ do
          (prop, args) <- closest
          ex <- once $ searchExamples $ unProp env $ test prop
          return (args, ex)

        success =
          search >>=
            \examples ->
              case examples of
                [(x,s)] -> return $ ExistUnique x s
                _ -> mzero

        failure =
          search >>=
            \examples ->
              case examples of
                [] -> return NotExist
                (x1,s1):(x2,s2):_ -> return $ AtLeastTwo x1 s1 x2 s2
                _ -> mzero
      -- }}}

atMost :: MonadLogic m => Int -> m a -> m [a]
atMost n m
  | n <= 0 = return []
  | otherwise = do
      m' <- msplit m
      case m' of
        Nothing -> return []
        Just (x,rest) ->
          (x:) `liftM` atMost (n-1) rest

-- }}}

------------------------------
-- Test constructors
------------------------------
-- {{{

quantify :: Quantification -> Property m -> Property m
quantify q (Property a) =
  makeAtomic $ Property $ local (\env -> env { quantification = q }) a

freshContext :: Testable m a => a -> Property m
freshContext = forAll

-- | Set the universal quantification context.
forAll :: Testable m a => a -> Property m
forAll = quantify Forall . test

-- | Set the existential quantification context.
exists :: Testable m a => a -> Property m
exists = quantify Exists . test

-- | Set the uniqueness quantification context.
--
-- Bear in mind that ∃! (x, y): p x y is not the same as ∃! x: ∃! y: p x y.
--
-- For example, ∃! x: ∃! y: |x| = |y| is true (it holds only when x=0), but ∃! (x,y): |x| = |y| is false (there are many such pairs).
--
-- As is customary in mathematics,
-- @'existsUnique' $ \\x y -> p x y@ is equivalent to
-- @'existsUnique' $ \\(x,y) -> p x y@ and not to
-- @'existsUnique' $ \\x -> 'existsUnique' $ \\y -> p x y@
-- (the latter, of course, may be explicitly written when desired).
--
-- That is, all the variables affected by the same uniqueness context are
-- quantified simultaneously as a tuple.
existsUnique :: Testable m a => a -> Property m
existsUnique = quantify ExistsUnique . test

-- | The '==>' operator can be used to express a restricting condition
-- under which a property should hold. It corresponds to implication in the
-- classical logic.
--
-- In the property @a '==>' b@, the quantification context of the consequent
-- (@b@) is the same as the quantification context of the property itself,
-- while the quantification context of the antecedent (@a@) is fresh
-- (universal by default, but may be overriden with the quantification
-- operators).
infixr 0 ==>
(==>) :: (Testable m c, Testable m a) => c -> a -> Property m
cond ==> prop = Property $ do
  env <- ask

  let
    counterExample = once $ searchCounterExamples $ unProp env $ freshContext cond

    antecedent = unProp env { quantification = Forall } $ freshContext prop

    badTestHook = lift $ testHook env BadTest

    success =
      ifte counterExample
        -- then
        (\ex -> do
          badTestHook
          return $ Vacuously ex
        )
        -- else
        (searchExamples antecedent)

    failure =
      ifte counterExample
        -- then
        (const $ do
          lift $ testHook env BadTest
          mzero
        )
        -- else
        (searchCounterExamples antecedent)

  return $ atomicProperty success failure

-- }}}
