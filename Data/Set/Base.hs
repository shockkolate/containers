{-# LANGUAGE CPP #-}
#if __GLASGOW_HASKELL__
{-# LANGUAGE DeriveDataTypeable, StandaloneDeriving #-}
#endif
#if !defined(TESTING) && __GLASGOW_HASKELL__ >= 703
{-# LANGUAGE Trustworthy #-}
#endif
#if __GLASGOW_HASKELL__ >= 708
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE TypeFamilies #-}
#endif

#include "containers.h"

-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Set.Base
-- Copyright   :  (c) Daan Leijen 2002
-- License     :  BSD-style
-- Maintainer  :  libraries@haskell.org
-- Stability   :  provisional
-- Portability :  portable
--
-- An efficient implementation of sets.
--
-- These modules are intended to be imported qualified, to avoid name
-- clashes with Prelude functions, e.g.
--
-- >  import Data.Set (Set)
-- >  import qualified Data.Set as Set
--
-- The implementation of 'Set' is based on /size balanced/ binary trees (or
-- trees of /bounded balance/) as described by:
--
--    * Stephen Adams, \"/Efficient sets: a balancing act/\",
--      Journal of Functional Programming 3(4):553-562, October 1993,
--      <http://www.swiss.ai.mit.edu/~adams/BB/>.
--
--    * J. Nievergelt and E.M. Reingold,
--      \"/Binary search trees of bounded balance/\",
--      SIAM journal of computing 2(1), March 1973.
--
-- Note that the implementation is /left-biased/ -- the elements of a
-- first argument are always preferred to the second, for example in
-- 'union' or 'insert'.  Of course, left-biasing can only be observed
-- when equality is an equivalence relation instead of structural
-- equality.
--
-- /Warning/: The size of the set must not exceed @maxBound::Int@. Violation of
-- this condition is not detected and if the size limit is exceeded, its
-- behaviour is undefined.
-----------------------------------------------------------------------------

-- [Note: Using INLINABLE]
-- ~~~~~~~~~~~~~~~~~~~~~~~
-- It is crucial to the performance that the functions specialize on the Ord
-- type when possible. GHC 7.0 and higher does this by itself when it sees th
-- unfolding of a function -- that is why all public functions are marked
-- INLINABLE (that exposes the unfolding).


-- [Note: Using INLINE]
-- ~~~~~~~~~~~~~~~~~~~~
-- For other compilers and GHC pre 7.0, we mark some of the functions INLINE.
-- We mark the functions that just navigate down the tree (lookup, insert,
-- delete and similar). That navigation code gets inlined and thus specialized
-- when possible. There is a price to pay -- code growth. The code INLINED is
-- therefore only the tree navigation, all the real work (rebalancing) is not
-- INLINED by using a NOINLINE.
--
-- All methods marked INLINE have to be nonrecursive -- a 'go' function doing
-- the real work is provided.


-- [Note: Type of local 'go' function]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- If the local 'go' function uses an Ord class, it sometimes heap-allocates
-- the Ord dictionary when the 'go' function does not have explicit type.
-- In that case we give 'go' explicit type. But this slightly decrease
-- performance, as the resulting 'go' function can float out to top level.


-- [Note: Local 'go' functions and capturing]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- As opposed to IntSet, when 'go' function captures an argument, increased
-- heap-allocation can occur: sometimes in a polymorphic function, the 'go'
-- floats out of its enclosing function and then it heap-allocates the
-- dictionary and the argument. Maybe it floats out too late and strictness
-- analyzer cannot see that these could be passed on stack.
--
-- For example, change 'member' so that its local 'go' function is not passing
-- argument x and then look at the resulting code for hedgeInt.


-- [Note: Order of constructors]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- The order of constructors of Set matters when considering performance.
-- Currently in GHC 7.0, when type has 2 constructors, a forward conditional
-- jump is made when successfully matching second constructor. Successful match
-- of first constructor results in the forward jump not taken.
-- On GHC 7.0, reordering constructors from Tip | Bin to Bin | Tip
-- improves the benchmark by up to 10% on x86.

module Data.Set.Base (
            -- * Set type
              Set(..)       -- instance Eq,Ord,Show,Read,Data,Typeable

            -- * Operators
            , (\\)

            -- * Query
            , null
            , size
            , member
            , notMember
            , lookupLT
            , lookupGT
            , lookupLE
            , lookupGE
            , isSubsetOf
            , isProperSubsetOf

            -- * Construction
            , empty
            , singleton
            , insert
            , delete

            -- * Combine
            , union
            , unions
            , difference
            , intersection

            -- * Filter
            , filter
            , partition
            , split
            , splitMember
            , splitRoot

            -- * Indexed
            , lookupIndex
            , findIndex
            , lookupElem
            , elemAt
            , deleteAt

            -- * Map
            , map
            , mapMonotonic

            -- * Folds
            , foldr
            , foldl
            -- ** Strict folds
            , foldr'
            , foldl'
            -- ** Legacy folds
            , fold

            -- * Min\/Max
            , findMin
            , findMax
            , deleteMin
            , deleteMax
            , deleteFindMin
            , deleteFindMax
            , maxView
            , minView

            -- * Conversion

            -- ** List
            , elems
            , toList
            , fromList

            -- ** Ordered list
            , toAscList
            , toDescList
            , fromAscList
            , fromDistinctAscList

            -- * Debugging
            , showTree
            , showTreeWith
            , valid

            -- Internals (for testing)
            , bin
            , balanced
            , link
            , merge
            ) where

import Prelude hiding (filter,foldl,foldr,null,map)
import qualified Data.List as List
import Data.Bits (shiftL, shiftR)
#if !MIN_VERSION_base(4,8,0)
import Data.Monoid (Monoid(..))
#endif
import qualified Data.Foldable as Foldable
import Data.Typeable
import Control.DeepSeq (NFData(rnf))

import Data.Utils.StrictFold
import Data.Utils.StrictPair

#if __GLASGOW_HASKELL__
import GHC.Exts ( build )
#if __GLASGOW_HASKELL__ >= 708
import qualified GHC.Exts as GHCExts
#endif
import Text.Read
import Data.Data
#endif


{--------------------------------------------------------------------
  Operators
--------------------------------------------------------------------}
infixl 9 \\ --

-- | /O(n+m)/. See 'difference'.
(\\) :: Ord a => Set a -> Set a -> Set a
m1 \\ m2 = difference m1 m2
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE (\\) #-}
#endif

{--------------------------------------------------------------------
  Sets are size balanced trees
--------------------------------------------------------------------}
-- | A set of values @a@.

-- See Note: Order of constructors
data Set a    = Bin {-# UNPACK #-} !Size !a !(Set a) !(Set a)
              | Tip

type Size     = Int

#if __GLASGOW_HASKELL__ >= 708
type role Set nominal
#endif

instance Ord a => Monoid (Set a) where
    mempty  = empty
    mappend = union
    mconcat = unions

instance Foldable.Foldable Set where
    fold = go
      where go Tip = mempty
            go (Bin 1 k _ _) = k
            go (Bin _ k l r) = go l `mappend` (k `mappend` go r)
    {-# INLINABLE fold #-}
    foldr = foldr
    {-# INLINE foldr #-}
    foldl = foldl
    {-# INLINE foldl #-}
    foldMap f t = go t
      where go Tip = mempty
            go (Bin 1 k _ _) = f k
            go (Bin _ k l r) = go l `mappend` (f k `mappend` go r)
    {-# INLINE foldMap #-}

#if MIN_VERSION_base(4,6,0)
    foldl' = foldl'
    {-# INLINE foldl' #-}
    foldr' = foldr'
    {-# INLINE foldr' #-}
#endif
#if MIN_VERSION_base(4,8,0)
    length = size
    {-# INLINE length #-}
    null   = null
    {-# INLINE null #-}
    toList = toList
    {-# INLINE toList #-}
    elem = go
      where STRICT_1_OF_2(go)
            go _ Tip = False
            go x (Bin _ y l r) = x == y || go x l || go x r
    {-# INLINABLE elem #-}
    minimum = findMin
    {-# INLINE minimum #-}
    maximum = findMax
    {-# INLINE maximum #-}
    sum = foldl' (+) 0
    {-# INLINABLE sum #-}
    product = foldl' (*) 1
    {-# INLINABLE product #-}
#endif


#if __GLASGOW_HASKELL__

{--------------------------------------------------------------------
  A Data instance
--------------------------------------------------------------------}

-- This instance preserves data abstraction at the cost of inefficiency.
-- We provide limited reflection services for the sake of data abstraction.

instance (Data a, Ord a) => Data (Set a) where
  gfoldl f z set = z fromList `f` (toList set)
  toConstr _     = fromListConstr
  gunfold k z c  = case constrIndex c of
    1 -> k (z fromList)
    _ -> error "gunfold"
  dataTypeOf _   = setDataType
  dataCast1 f    = gcast1 f

fromListConstr :: Constr
fromListConstr = mkConstr setDataType "fromList" [] Prefix

setDataType :: DataType
setDataType = mkDataType "Data.Set.Base.Set" [fromListConstr]

#endif

{--------------------------------------------------------------------
  Query
--------------------------------------------------------------------}
-- | /O(1)/. Is this the empty set?
null :: Set a -> Bool
null Tip      = True
null (Bin {}) = False
{-# INLINE null #-}

-- | /O(1)/. The number of elements in the set.
size :: Set a -> Int
size Tip = 0
size (Bin sz _ _ _) = sz
{-# INLINE size #-}

-- | /O(log n)/. Is the element in the set?
member :: Ord a => a -> Set a -> Bool
member = go
  where
    STRICT_1_OF_2(go)
    go _ Tip = False
    go x (Bin _ y l r) = case compare x y of
      LT -> go x l
      GT -> go x r
      EQ -> True
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE member #-}
#else
{-# INLINE member #-}
#endif

-- | /O(log n)/. Is the element not in the set?
notMember :: Ord a => a -> Set a -> Bool
notMember a t = not $ member a t
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE notMember #-}
#else
{-# INLINE notMember #-}
#endif

-- | /O(log n)/. Find largest element smaller than the given one.
--
-- > lookupLT 3 (fromList [3, 5]) == Nothing
-- > lookupLT 5 (fromList [3, 5]) == Just 3
lookupLT :: Ord a => a -> Set a -> Maybe a
lookupLT = goNothing
  where
    STRICT_1_OF_2(goNothing)
    goNothing _ Tip = Nothing
    goNothing x (Bin _ y l r) | x <= y = goNothing x l
                              | otherwise = goJust x y r

    STRICT_1_OF_3(goJust)
    goJust _ best Tip = Just best
    goJust x best (Bin _ y l r) | x <= y = goJust x best l
                                | otherwise = goJust x y r
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE lookupLT #-}
#else
{-# INLINE lookupLT #-}
#endif

-- | /O(log n)/. Find smallest element greater than the given one.
--
-- > lookupGT 4 (fromList [3, 5]) == Just 5
-- > lookupGT 5 (fromList [3, 5]) == Nothing
lookupGT :: Ord a => a -> Set a -> Maybe a
lookupGT = goNothing
  where
    STRICT_1_OF_2(goNothing)
    goNothing _ Tip = Nothing
    goNothing x (Bin _ y l r) | x < y = goJust x y l
                              | otherwise = goNothing x r

    STRICT_1_OF_3(goJust)
    goJust _ best Tip = Just best
    goJust x best (Bin _ y l r) | x < y = goJust x y l
                                | otherwise = goJust x best r
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE lookupGT #-}
#else
{-# INLINE lookupGT #-}
#endif

-- | /O(log n)/. Find largest element smaller or equal to the given one.
--
-- > lookupLE 2 (fromList [3, 5]) == Nothing
-- > lookupLE 4 (fromList [3, 5]) == Just 3
-- > lookupLE 5 (fromList [3, 5]) == Just 5
lookupLE :: Ord a => a -> Set a -> Maybe a
lookupLE = goNothing
  where
    STRICT_1_OF_2(goNothing)
    goNothing _ Tip = Nothing
    goNothing x (Bin _ y l r) = case compare x y of LT -> goNothing x l
                                                    EQ -> Just y
                                                    GT -> goJust x y r

    STRICT_1_OF_3(goJust)
    goJust _ best Tip = Just best
    goJust x best (Bin _ y l r) = case compare x y of LT -> goJust x best l
                                                      EQ -> Just y
                                                      GT -> goJust x y r
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE lookupLE #-}
#else
{-# INLINE lookupLE #-}
#endif

-- | /O(log n)/. Find smallest element greater or equal to the given one.
--
-- > lookupGE 3 (fromList [3, 5]) == Just 3
-- > lookupGE 4 (fromList [3, 5]) == Just 5
-- > lookupGE 6 (fromList [3, 5]) == Nothing
lookupGE :: Ord a => a -> Set a -> Maybe a
lookupGE = goNothing
  where
    STRICT_1_OF_2(goNothing)
    goNothing _ Tip = Nothing
    goNothing x (Bin _ y l r) = case compare x y of LT -> goJust x y l
                                                    EQ -> Just y
                                                    GT -> goNothing x r

    STRICT_1_OF_3(goJust)
    goJust _ best Tip = Just best
    goJust x best (Bin _ y l r) = case compare x y of LT -> goJust x y l
                                                      EQ -> Just y
                                                      GT -> goJust x best r
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE lookupGE #-}
#else
{-# INLINE lookupGE #-}
#endif

{--------------------------------------------------------------------
  Construction
--------------------------------------------------------------------}
-- | /O(1)/. The empty set.
empty  :: Set a
empty = Tip
{-# INLINE empty #-}

-- | /O(1)/. Create a singleton set.
singleton :: a -> Set a
singleton x = Bin 1 x Tip Tip
{-# INLINE singleton #-}

{--------------------------------------------------------------------
  Insertion, Deletion
--------------------------------------------------------------------}
-- | /O(log n)/. Insert an element in a set.
-- If the set already contains an element equal to the given value,
-- it is replaced with the new value.

-- See Note: Type of local 'go' function
insert :: Ord a => a -> Set a -> Set a
insert = go
  where
    go :: Ord a => a -> Set a -> Set a
    STRICT_1_OF_2(go)
    go x Tip = singleton x
    go x (Bin sz y l r) = case compare x y of
        LT -> balanceL y (go x l) r
        GT -> balanceR y l (go x r)
        EQ -> Bin sz x l r
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE insert #-}
#else
{-# INLINE insert #-}
#endif

-- Insert an element to the set only if it is not in the set.
-- Used by `union`.

-- See Note: Type of local 'go' function
insertR :: Ord a => a -> Set a -> Set a
insertR = go
  where
    go :: Ord a => a -> Set a -> Set a
    STRICT_1_OF_2(go)
    go x Tip = singleton x
    go x t@(Bin _ y l r) = case compare x y of
        LT -> balanceL y (go x l) r
        GT -> balanceR y l (go x r)
        EQ -> t
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE insertR #-}
#else
{-# INLINE insertR #-}
#endif

-- | /O(log n)/. Delete an element from a set.

-- See Note: Type of local 'go' function
delete :: Ord a => a -> Set a -> Set a
delete = go
  where
    go :: Ord a => a -> Set a -> Set a
    STRICT_1_OF_2(go)
    go _ Tip = Tip
    go x (Bin _ y l r) = case compare x y of
        LT -> balanceR y (go x l) r
        GT -> balanceL y l (go x r)
        EQ -> glue l r
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE delete #-}
#else
{-# INLINE delete #-}
#endif

{--------------------------------------------------------------------
  Subset
--------------------------------------------------------------------}
-- | /O(n+m)/. Is this a proper subset? (ie. a subset but not equal).
isProperSubsetOf :: Ord a => Set a -> Set a -> Bool
isProperSubsetOf s1 s2
    = (size s1 < size s2) && (isSubsetOf s1 s2)
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE isProperSubsetOf #-}
#endif


-- | /O(n+m)/. Is this a subset?
-- @(s1 `isSubsetOf` s2)@ tells whether @s1@ is a subset of @s2@.
isSubsetOf :: Ord a => Set a -> Set a -> Bool
isSubsetOf t1 t2
  = (size t1 <= size t2) && (isSubsetOfX t1 t2)
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE isSubsetOf #-}
#endif

isSubsetOfX :: Ord a => Set a -> Set a -> Bool
isSubsetOfX Tip _ = True
isSubsetOfX _ Tip = False
isSubsetOfX (Bin _ x l r) t
  = found && isSubsetOfX l lt && isSubsetOfX r gt
  where
    (lt,found,gt) = splitMember x t
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE isSubsetOfX #-}
#endif


{--------------------------------------------------------------------
  Minimal, Maximal
--------------------------------------------------------------------}
-- | /O(log n)/. The minimal element of a set.
findMin :: Set a -> a
findMin (Bin _ x Tip _) = x
findMin (Bin _ _ l _)   = findMin l
findMin Tip             = error "Set.findMin: empty set has no minimal element"

-- | /O(log n)/. The maximal element of a set.
findMax :: Set a -> a
findMax (Bin _ x _ Tip)  = x
findMax (Bin _ _ _ r)    = findMax r
findMax Tip              = error "Set.findMax: empty set has no maximal element"

-- | /O(log n)/. Delete the minimal element. Returns an empty set if the set is empty.
deleteMin :: Set a -> Set a
deleteMin (Bin _ _ Tip r) = r
deleteMin (Bin _ x l r)   = balanceR x (deleteMin l) r
deleteMin Tip             = Tip

-- | /O(log n)/. Delete the maximal element. Returns an empty set if the set is empty.
deleteMax :: Set a -> Set a
deleteMax (Bin _ _ l Tip) = l
deleteMax (Bin _ x l r)   = balanceL x l (deleteMax r)
deleteMax Tip             = Tip

{--------------------------------------------------------------------
  Union.
--------------------------------------------------------------------}
-- | The union of a list of sets: (@'unions' == 'foldl' 'union' 'empty'@).
unions :: Ord a => [Set a] -> Set a
unions = foldlStrict union empty
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE unions #-}
#endif

-- | /O(n+m)/. The union of two sets, preferring the first set when
-- equal elements are encountered.
-- The implementation uses the efficient /hedge-union/ algorithm.
union :: Ord a => Set a -> Set a -> Set a
union Tip t2  = t2
union t1 Tip  = t1
union t1 t2 = hedgeUnion NothingS NothingS t1 t2
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE union #-}
#endif

hedgeUnion :: Ord a => MaybeS a -> MaybeS a -> Set a -> Set a -> Set a
hedgeUnion _   _   t1  Tip = t1
hedgeUnion blo bhi Tip (Bin _ x l r) = link x (filterGt blo l) (filterLt bhi r)
hedgeUnion _   _   t1  (Bin _ x Tip Tip) = insertR x t1   -- According to benchmarks, this special case increases
                                                          -- performance up to 30%. It does not help in difference or intersection.
hedgeUnion blo bhi (Bin _ x l r) t2 = link x (hedgeUnion blo bmi l (trim blo bmi t2))
                                             (hedgeUnion bmi bhi r (trim bmi bhi t2))
  where bmi = JustS x
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE hedgeUnion #-}
#endif

{--------------------------------------------------------------------
  Difference
--------------------------------------------------------------------}
-- | /O(n+m)/. Difference of two sets.
-- The implementation uses an efficient /hedge/ algorithm comparable with /hedge-union/.
difference :: Ord a => Set a -> Set a -> Set a
difference Tip _   = Tip
difference t1 Tip  = t1
difference t1 t2   = hedgeDiff NothingS NothingS t1 t2
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE difference #-}
#endif

hedgeDiff :: Ord a => MaybeS a -> MaybeS a -> Set a -> Set a -> Set a
hedgeDiff _   _   Tip           _ = Tip
hedgeDiff blo bhi (Bin _ x l r) Tip = link x (filterGt blo l) (filterLt bhi r)
hedgeDiff blo bhi t (Bin _ x l r) = merge (hedgeDiff blo bmi (trim blo bmi t) l)
                                          (hedgeDiff bmi bhi (trim bmi bhi t) r)
  where bmi = JustS x
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE hedgeDiff #-}
#endif

{--------------------------------------------------------------------
  Intersection
--------------------------------------------------------------------}
-- | /O(n+m)/. The intersection of two sets.  The implementation uses an
-- efficient /hedge/ algorithm comparable with /hedge-union/.  Elements of the
-- result come from the first set, so for example
--
-- > import qualified Data.Set as S
-- > data AB = A | B deriving Show
-- > instance Ord AB where compare _ _ = EQ
-- > instance Eq AB where _ == _ = True
-- > main = print (S.singleton A `S.intersection` S.singleton B,
-- >               S.singleton B `S.intersection` S.singleton A)
--
-- prints @(fromList [A],fromList [B])@.
intersection :: Ord a => Set a -> Set a -> Set a
intersection Tip _ = Tip
intersection _ Tip = Tip
intersection t1 t2 = hedgeInt NothingS NothingS t1 t2
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE intersection #-}
#endif

hedgeInt :: Ord a => MaybeS a -> MaybeS a -> Set a -> Set a -> Set a
hedgeInt _ _ _   Tip = Tip
hedgeInt _ _ Tip _   = Tip
hedgeInt blo bhi (Bin _ x l r) t2 = let l' = hedgeInt blo bmi l (trim blo bmi t2)
                                        r' = hedgeInt bmi bhi r (trim bmi bhi t2)
                                    in if x `member` t2 then link x l' r' else merge l' r'
  where bmi = JustS x
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE hedgeInt #-}
#endif

{--------------------------------------------------------------------
  Filter and partition
--------------------------------------------------------------------}
-- | /O(n)/. Filter all elements that satisfy the predicate.
filter :: (a -> Bool) -> Set a -> Set a
filter _ Tip = Tip
filter p (Bin _ x l r)
    | p x       = link x (filter p l) (filter p r)
    | otherwise = merge (filter p l) (filter p r)

-- | /O(n)/. Partition the set into two sets, one with all elements that satisfy
-- the predicate and one with all elements that don't satisfy the predicate.
-- See also 'split'.
partition :: (a -> Bool) -> Set a -> (Set a,Set a)
partition p0 t0 = toPair $ go p0 t0
  where
    go _ Tip = (Tip :*: Tip)
    go p (Bin _ x l r) = case (go p l, go p r) of
      ((l1 :*: l2), (r1 :*: r2))
        | p x       -> link x l1 r1 :*: merge l2 r2
        | otherwise -> merge l1 r1 :*: link x l2 r2

{----------------------------------------------------------------------
  Map
----------------------------------------------------------------------}

-- | /O(n*log n)/.
-- @'map' f s@ is the set obtained by applying @f@ to each element of @s@.
--
-- It's worth noting that the size of the result may be smaller if,
-- for some @(x,y)@, @x \/= y && f x == f y@

map :: Ord b => (a->b) -> Set a -> Set b
map f = fromList . List.map f . toList
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE map #-}
#endif

-- | /O(n)/. The
--
-- @'mapMonotonic' f s == 'map' f s@, but works only when @f@ is monotonic.
-- /The precondition is not checked./
-- Semi-formally, we have:
--
-- > and [x < y ==> f x < f y | x <- ls, y <- ls]
-- >                     ==> mapMonotonic f s == map f s
-- >     where ls = toList s

mapMonotonic :: (a->b) -> Set a -> Set b
mapMonotonic _ Tip = Tip
mapMonotonic f (Bin sz x l r) = Bin sz (f x) (mapMonotonic f l) (mapMonotonic f r)

{--------------------------------------------------------------------
  Fold
--------------------------------------------------------------------}
-- | /O(n)/. Fold the elements in the set using the given right-associative
-- binary operator. This function is an equivalent of 'foldr' and is present
-- for compatibility only.
--
-- /Please note that fold will be deprecated in the future and removed./
fold :: (a -> b -> b) -> b -> Set a -> b
fold = foldr
{-# INLINE fold #-}

-- | /O(n)/. Fold the elements in the set using the given right-associative
-- binary operator, such that @'foldr' f z == 'Prelude.foldr' f z . 'toAscList'@.
--
-- For example,
--
-- > toAscList set = foldr (:) [] set
foldr :: (a -> b -> b) -> b -> Set a -> b
foldr f z = go z
  where
    go z' Tip           = z'
    go z' (Bin _ x l r) = go (f x (go z' r)) l
{-# INLINE foldr #-}

-- | /O(n)/. A strict version of 'foldr'. Each application of the operator is
-- evaluated before using the result in the next application. This
-- function is strict in the starting value.
foldr' :: (a -> b -> b) -> b -> Set a -> b
foldr' f z = go z
  where
    STRICT_1_OF_2(go)
    go z' Tip           = z'
    go z' (Bin _ x l r) = go (f x (go z' r)) l
{-# INLINE foldr' #-}

-- | /O(n)/. Fold the elements in the set using the given left-associative
-- binary operator, such that @'foldl' f z == 'Prelude.foldl' f z . 'toAscList'@.
--
-- For example,
--
-- > toDescList set = foldl (flip (:)) [] set
foldl :: (a -> b -> a) -> a -> Set b -> a
foldl f z = go z
  where
    go z' Tip           = z'
    go z' (Bin _ x l r) = go (f (go z' l) x) r
{-# INLINE foldl #-}

-- | /O(n)/. A strict version of 'foldl'. Each application of the operator is
-- evaluated before using the result in the next application. This
-- function is strict in the starting value.
foldl' :: (a -> b -> a) -> a -> Set b -> a
foldl' f z = go z
  where
    STRICT_1_OF_2(go)
    go z' Tip           = z'
    go z' (Bin _ x l r) = go (f (go z' l) x) r
{-# INLINE foldl' #-}

{--------------------------------------------------------------------
  List variations
--------------------------------------------------------------------}
-- | /O(n)/. An alias of 'toAscList'. The elements of a set in ascending order.
-- Subject to list fusion.
elems :: Set a -> [a]
elems = toAscList

{--------------------------------------------------------------------
  Lists
--------------------------------------------------------------------}
#if __GLASGOW_HASKELL__ >= 708
instance (Ord a) => GHCExts.IsList (Set a) where
  type Item (Set a) = a
  fromList = fromList
  toList   = toList
#endif

-- | /O(n)/. Convert the set to a list of elements. Subject to list fusion.
toList :: Set a -> [a]
toList = toAscList

-- | /O(n)/. Convert the set to an ascending list of elements. Subject to list fusion.
toAscList :: Set a -> [a]
toAscList = foldr (:) []

-- | /O(n)/. Convert the set to a descending list of elements. Subject to list
-- fusion.
toDescList :: Set a -> [a]
toDescList = foldl (flip (:)) []

-- List fusion for the list generating functions.
#if __GLASGOW_HASKELL__
-- The foldrFB and foldlFB are foldr and foldl equivalents, used for list fusion.
-- They are important to convert unfused to{Asc,Desc}List back, see mapFB in prelude.
foldrFB :: (a -> b -> b) -> b -> Set a -> b
foldrFB = foldr
{-# INLINE[0] foldrFB #-}
foldlFB :: (a -> b -> a) -> a -> Set b -> a
foldlFB = foldl
{-# INLINE[0] foldlFB #-}

-- Inline elems and toList, so that we need to fuse only toAscList.
{-# INLINE elems #-}
{-# INLINE toList #-}

-- The fusion is enabled up to phase 2 included. If it does not succeed,
-- convert in phase 1 the expanded to{Asc,Desc}List calls back to
-- to{Asc,Desc}List.  In phase 0, we inline fold{lr}FB (which were used in
-- a list fusion, otherwise it would go away in phase 1), and let compiler do
-- whatever it wants with to{Asc,Desc}List -- it was forbidden to inline it
-- before phase 0, otherwise the fusion rules would not fire at all.
{-# NOINLINE[0] toAscList #-}
{-# NOINLINE[0] toDescList #-}
{-# RULES "Set.toAscList" [~1] forall s . toAscList s = build (\c n -> foldrFB c n s) #-}
{-# RULES "Set.toAscListBack" [1] foldrFB (:) [] = toAscList #-}
{-# RULES "Set.toDescList" [~1] forall s . toDescList s = build (\c n -> foldlFB (\xs x -> c x xs) n s) #-}
{-# RULES "Set.toDescListBack" [1] foldlFB (\xs x -> x : xs) [] = toDescList #-}
#endif

-- | /O(n*log n)/. Create a set from a list of elements.
--
-- If the elements are ordered, a linear-time implementation is used,
-- with the performance equal to 'fromDistinctAscList'.

-- For some reason, when 'singleton' is used in fromList or in
-- create, it is not inlined, so we inline it manually.
fromList :: Ord a => [a] -> Set a
fromList [] = Tip
fromList [x] = Bin 1 x Tip Tip
fromList (x0 : xs0) | not_ordered x0 xs0 = fromList' (Bin 1 x0 Tip Tip) xs0
                    | otherwise = go (1::Int) (Bin 1 x0 Tip Tip) xs0
  where
    not_ordered _ [] = False
    not_ordered x (y : _) = x >= y
    {-# INLINE not_ordered #-}

    fromList' t0 xs = foldlStrict ins t0 xs
      where ins t x = insert x t

    STRICT_1_OF_3(go)
    go _ t [] = t
    go _ t [x] = insertMax x t
    go s l xs@(x : xss) | not_ordered x xss = fromList' l xs
                        | otherwise = case create s xss of
                            (r, ys, []) -> go (s `shiftL` 1) (link x l r) ys
                            (r, _,  ys) -> fromList' (link x l r) ys

    -- The create is returning a triple (tree, xs, ys). Both xs and ys
    -- represent not yet processed elements and only one of them can be nonempty.
    -- If ys is nonempty, the keys in ys are not ordered with respect to tree
    -- and must be inserted using fromList'. Otherwise the keys have been
    -- ordered so far.
    STRICT_1_OF_2(create)
    create _ [] = (Tip, [], [])
    create s xs@(x : xss)
      | s == 1 = if not_ordered x xss then (Bin 1 x Tip Tip, [], xss)
                                      else (Bin 1 x Tip Tip, xss, [])
      | otherwise = case create (s `shiftR` 1) xs of
                      res@(_, [], _) -> res
                      (l, [y], zs) -> (insertMax y l, [], zs)
                      (l, ys@(y:yss), _) | not_ordered y yss -> (l, [], ys)
                                         | otherwise -> case create (s `shiftR` 1) yss of
                                                   (r, zs, ws) -> (link y l r, zs, ws)
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE fromList #-}
#endif

{--------------------------------------------------------------------
  Building trees from ascending/descending lists can be done in linear time.

  Note that if [xs] is ascending that:
    fromAscList xs == fromList xs
--------------------------------------------------------------------}
-- | /O(n)/. Build a set from an ascending list in linear time.
-- /The precondition (input list is ascending) is not checked./
fromAscList :: Eq a => [a] -> Set a
fromAscList xs
  = fromDistinctAscList (combineEq xs)
  where
  -- [combineEq xs] combines equal elements with [const] in an ordered list [xs]
  combineEq xs'
    = case xs' of
        []     -> []
        [x]    -> [x]
        (x:xx) -> combineEq' x xx

  combineEq' z [] = [z]
  combineEq' z (x:xs')
    | z==x      =   combineEq' z xs'
    | otherwise = z:combineEq' x xs'
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE fromAscList #-}
#endif


-- | /O(n)/. Build a set from an ascending list of distinct elements in linear time.
-- /The precondition (input list is strictly ascending) is not checked./

-- For some reason, when 'singleton' is used in fromDistinctAscList or in
-- create, it is not inlined, so we inline it manually.
fromDistinctAscList :: [a] -> Set a
fromDistinctAscList [] = Tip
fromDistinctAscList (x0 : xs0) = go (1::Int) (Bin 1 x0 Tip Tip) xs0
  where
    STRICT_1_OF_3(go)
    go _ t [] = t
    go s l (x : xs) = case create s xs of
                        (r, ys) -> go (s `shiftL` 1) (link x l r) ys

    STRICT_1_OF_2(create)
    create _ [] = (Tip, [])
    create s xs@(x : xs')
      | s == 1 = (Bin 1 x Tip Tip, xs')
      | otherwise = case create (s `shiftR` 1) xs of
                      res@(_, []) -> res
                      (l, y:ys) -> case create (s `shiftR` 1) ys of
                        (r, zs) -> (link y l r, zs)

{--------------------------------------------------------------------
  Eq converts the set to a list. In a lazy setting, this
  actually seems one of the faster methods to compare two trees
  and it is certainly the simplest :-)
--------------------------------------------------------------------}
instance Eq a => Eq (Set a) where
  t1 == t2  = (size t1 == size t2) && (toAscList t1 == toAscList t2)

{--------------------------------------------------------------------
  Ord
--------------------------------------------------------------------}

instance Ord a => Ord (Set a) where
    compare s1 s2 = compare (toAscList s1) (toAscList s2)

{--------------------------------------------------------------------
  Show
--------------------------------------------------------------------}
instance Show a => Show (Set a) where
  showsPrec p xs = showParen (p > 10) $
    showString "fromList " . shows (toList xs)

{--------------------------------------------------------------------
  Read
--------------------------------------------------------------------}
instance (Read a, Ord a) => Read (Set a) where
#ifdef __GLASGOW_HASKELL__
  readPrec = parens $ prec 10 $ do
    Ident "fromList" <- lexP
    xs <- readPrec
    return (fromList xs)

  readListPrec = readListPrecDefault
#else
  readsPrec p = readParen (p > 10) $ \ r -> do
    ("fromList",s) <- lex r
    (xs,t) <- reads s
    return (fromList xs,t)
#endif

{--------------------------------------------------------------------
  Typeable/Data
--------------------------------------------------------------------}

INSTANCE_TYPEABLE1(Set,setTc,"Set")

{--------------------------------------------------------------------
  NFData
--------------------------------------------------------------------}

instance NFData a => NFData (Set a) where
    rnf Tip           = ()
    rnf (Bin _ y l r) = rnf y `seq` rnf l `seq` rnf r

{--------------------------------------------------------------------
  Utility functions that return sub-ranges of the original
  tree. Some functions take a `Maybe value` as an argument to
  allow comparisons against infinite values. These are called `blow`
  (Nothing is -\infty) and `bhigh` (here Nothing is +\infty).
  We use MaybeS value, which is a Maybe strict in the Just case.

  [trim blow bhigh t]   A tree that is either empty or where [x > blow]
                        and [x < bhigh] for the value [x] of the root.
  [filterGt blow t]     A tree where for all values [k]. [k > blow]
  [filterLt bhigh t]    A tree where for all values [k]. [k < bhigh]

  [split k t]           Returns two trees [l] and [r] where all values
                        in [l] are <[k] and all keys in [r] are >[k].
  [splitMember k t]     Just like [split] but also returns whether [k]
                        was found in the tree.
--------------------------------------------------------------------}

data MaybeS a = NothingS | JustS !a

{--------------------------------------------------------------------
  [trim blo bhi t] trims away all subtrees that surely contain no
  values between the range [blo] to [bhi]. The returned tree is either
  empty or the key of the root is between @blo@ and @bhi@.
--------------------------------------------------------------------}
trim :: Ord a => MaybeS a -> MaybeS a -> Set a -> Set a
trim NothingS   NothingS   t = t
trim (JustS lx) NothingS   t = greater lx t where greater lo (Bin _ x _ r) | x <= lo = greater lo r
                                                  greater _  t' = t'
trim NothingS   (JustS hx) t = lesser hx t  where lesser  hi (Bin _ x l _) | x >= hi = lesser  hi l
                                                  lesser  _  t' = t'
trim (JustS lx) (JustS hx) t = middle lx hx t  where middle lo hi (Bin _ x _ r) | x <= lo = middle lo hi r
                                                     middle lo hi (Bin _ x l _) | x >= hi = middle lo hi l
                                                     middle _  _  t' = t'
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE trim #-}
#endif

{--------------------------------------------------------------------
  [filterGt b t] filter all values >[b] from tree [t]
  [filterLt b t] filter all values <[b] from tree [t]
--------------------------------------------------------------------}
filterGt :: Ord a => MaybeS a -> Set a -> Set a
filterGt NothingS t = t
filterGt (JustS b) t = filter' b t
  where filter' _   Tip = Tip
        filter' b' (Bin _ x l r) =
          case compare b' x of LT -> link x (filter' b' l) r
                               EQ -> r
                               GT -> filter' b' r
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE filterGt #-}
#endif

filterLt :: Ord a => MaybeS a -> Set a -> Set a
filterLt NothingS t = t
filterLt (JustS b) t = filter' b t
  where filter' _   Tip = Tip
        filter' b' (Bin _ x l r) =
          case compare x b' of LT -> link x l (filter' b' r)
                               EQ -> l
                               GT -> filter' b' l
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE filterLt #-}
#endif

{--------------------------------------------------------------------
  Split
--------------------------------------------------------------------}
-- | /O(log n)/. The expression (@'split' x set@) is a pair @(set1,set2)@
-- where @set1@ comprises the elements of @set@ less than @x@ and @set2@
-- comprises the elements of @set@ greater than @x@.
split :: Ord a => a -> Set a -> (Set a,Set a)
split x0 t0 = toPair $ go x0 t0
  where
    go _ Tip = (Tip :*: Tip)
    go x (Bin _ y l r)
      = case compare x y of
          LT -> let (lt :*: gt) = go x l in (lt :*: link y gt r)
          GT -> let (lt :*: gt) = go x r in (link y l lt :*: gt)
          EQ -> (l :*: r)
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE split #-}
#endif

-- | /O(log n)/. Performs a 'split' but also returns whether the pivot
-- element was found in the original set.
splitMember :: Ord a => a -> Set a -> (Set a,Bool,Set a)
splitMember _ Tip = (Tip, False, Tip)
splitMember x (Bin _ y l r)
   = case compare x y of
       LT -> let (lt, found, gt) = splitMember x l
                 gt' = link y gt r
             in gt' `seq` (lt, found, gt')
       GT -> let (lt, found, gt) = splitMember x r
                 lt' = link y l lt
             in lt' `seq` (lt', found, gt)
       EQ -> (l, True, r)
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE splitMember #-}
#endif

{--------------------------------------------------------------------
  Indexing
--------------------------------------------------------------------}

-- | /O(log n)/. Return the /index/ of an element, which is its zero-based
-- index in the sorted sequence of elements. The index is a number from /0/ up
-- to, but not including, the 'size' of the set. Calls 'error' when the element
-- is not a 'member' of the set.
--
-- > findIndex 2 (fromList [5,3])    Error: element is not in the set
-- > findIndex 3 (fromList [5,3]) == 0
-- > findIndex 5 (fromList [5,3]) == 1
-- > findIndex 6 (fromList [5,3])    Error: element is not in the set

-- See Note: Type of local 'go' function
findIndex :: Ord a => a -> Set a -> Int
findIndex = go 0
  where
    go :: Ord a => Int -> a -> Set a -> Int
    STRICT_1_OF_3(go)
    STRICT_2_OF_3(go)
    go _   _ Tip  = error "Set.findIndex: element is not in the set"
    go idx x (Bin _ kx l r) = case compare x kx of
      LT -> go idx x l
      GT -> go (idx + size l + 1) x r
      EQ -> idx + size l
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE findIndex #-}
#endif

-- | /O(log n)/. Lookup the /index/ of an element, which is its zero-based index in
-- the sorted sequence of elements. The index is a number from /0/ up to, but not
-- including, the 'size' of the set.
--
-- > isJust   (lookupIndex 2 (fromList [5,3])) == False
-- > fromJust (lookupIndex 3 (fromList [5,3])) == 0
-- > fromJust (lookupIndex 5 (fromList [5,3])) == 1
-- > isJust   (lookupIndex 6 (fromList [5,3])) == False

-- See Note: Type of local 'go' function
lookupIndex :: Ord a => a -> Set a -> Maybe Int
lookupIndex = go 0
  where
    go :: Ord a => Int -> a -> Set a -> Maybe Int
    STRICT_1_OF_3(go)
    STRICT_2_OF_3(go)
    go _   _ Tip  = Nothing
    go idx x (Bin _ kx l r) = case compare x kx of
      LT -> go idx x l
      GT -> go (idx + size l + 1) x r
      EQ -> Just $! idx + size l
#if __GLASGOW_HASKELL__ >= 700
{-# INLINABLE lookupIndex #-}
#endif

-- | /O(log n)/. Lookup an element by its /index/, i.e. by its zero-based
-- index in the sorted sequence of elements.
--
-- > fromJust (lookupElem 0 (fromList [5,3])) == 3
-- > fromJust (lookupElem 1 (fromList [5,3])) == 5
-- > isJust   (lookupElem 2 (fromList [5,3])) == False

lookupElem :: Int -> Set a -> Maybe a
STRICT_1_OF_2(lookupElem)
lookupElem _ Tip = Nothing
lookupElem i (Bin _ x l r)
  = case compare i sizeL of
      LT -> lookupElem i l
      GT -> lookupElem (i-sizeL-1) r
      EQ -> Just x
  where
    sizeL = size l

-- | /O(log n)/. Retrieve an element by its /index/, i.e. by its zero-based
-- index in the sorted sequence of elements. If the /index/ is out of range (less
-- than zero, greater or equal to 'size' of the set), 'error' is called.
--
-- > elemAt 0 (fromList [5,3]) == 3
-- > elemAt 1 (fromList [5,3]) == 5
-- > elemAt 2 (fromList [5,3])    Error: index out of range

elemAt :: Int -> Set a -> a
STRICT_1_OF_2(elemAt)
elemAt _ Tip = error "Set.elemAt: index out of range"
elemAt i (Bin _ x l r)
  = case compare i sizeL of
      LT -> elemAt i l
      GT -> elemAt (i-sizeL-1) r
      EQ -> x
  where
    sizeL = size l

-- | /O(log n)/. Delete the element at /index/, i.e. by its zero-based index in
-- the sorted sequence of elements. If the /index/ is out of range (less than zero,
-- greater or equal to 'size' of the set), 'error' is called.
--
-- > deleteAt 0    (fromList [5,3]) == singleton 5
-- > deleteAt 1    (fromList [5,3]) == singleton 3
-- > deleteAt 2    (fromList [5,3])    Error: index out of range
-- > deleteAt (-1) (fromList [5,3])    Error: index out of range

deleteAt :: Int -> Set a -> Set a
deleteAt i t = i `seq`
  case t of
    Tip -> error "Set.deleteAt: index out of range"
    Bin _ x l r -> case compare i sizeL of
      LT -> balanceR x (deleteAt i l) r
      GT -> balanceL x l (deleteAt (i-sizeL-1) r)
      EQ -> glue l r
      where
        sizeL = size l


{--------------------------------------------------------------------
  Utility functions that maintain the balance properties of the tree.
  All constructors assume that all values in [l] < [x] and all values
  in [r] > [x], and that [l] and [r] are valid trees.

  In order of sophistication:
    [Bin sz x l r]    The type constructor.
    [bin x l r]       Maintains the correct size, assumes that both [l]
                      and [r] are balanced with respect to each other.
    [balance x l r]   Restores the balance and size.
                      Assumes that the original tree was balanced and
                      that [l] or [r] has changed by at most one element.
    [link x l r]      Restores balance and size.

  Furthermore, we can construct a new tree from two trees. Both operations
  assume that all values in [l] < all values in [r] and that [l] and [r]
  are valid:
    [glue l r]        Glues [l] and [r] together. Assumes that [l] and
                      [r] are already balanced with respect to each other.
    [merge l r]       Merges two trees and restores balance.

  Note: in contrast to Adam's paper, we use (<=) comparisons instead
  of (<) comparisons in [link], [merge] and [balance].
  Quickcheck (on [difference]) showed that this was necessary in order
  to maintain the invariants. It is quite unsatisfactory that I haven't
  been able to find out why this is actually the case! Fortunately, it
  doesn't hurt to be a bit more conservative.
--------------------------------------------------------------------}

{--------------------------------------------------------------------
  Link
--------------------------------------------------------------------}
link :: a -> Set a -> Set a -> Set a
link x Tip r  = insertMin x r
link x l Tip  = insertMax x l
link x l@(Bin sizeL y ly ry) r@(Bin sizeR z lz rz)
  | delta*sizeL < sizeR  = balanceL z (link x l lz) rz
  | delta*sizeR < sizeL  = balanceR y ly (link x ry r)
  | otherwise            = bin x l r


-- insertMin and insertMax don't perform potentially expensive comparisons.
insertMax,insertMin :: a -> Set a -> Set a
insertMax x t
  = case t of
      Tip -> singleton x
      Bin _ y l r
          -> balanceR y l (insertMax x r)

insertMin x t
  = case t of
      Tip -> singleton x
      Bin _ y l r
          -> balanceL y (insertMin x l) r

{--------------------------------------------------------------------
  [merge l r]: merges two trees.
--------------------------------------------------------------------}
merge :: Set a -> Set a -> Set a
merge Tip r   = r
merge l Tip   = l
merge l@(Bin sizeL x lx rx) r@(Bin sizeR y ly ry)
  | delta*sizeL < sizeR = balanceL y (merge l ly) ry
  | delta*sizeR < sizeL = balanceR x lx (merge rx r)
  | otherwise           = glue l r

{--------------------------------------------------------------------
  [glue l r]: glues two trees together.
  Assumes that [l] and [r] are already balanced with respect to each other.
--------------------------------------------------------------------}
glue :: Set a -> Set a -> Set a
glue Tip r = r
glue l Tip = l
glue l r
  | size l > size r = let (m,l') = deleteFindMax l in balanceR m l' r
  | otherwise       = let (m,r') = deleteFindMin r in balanceL m l r'

-- | /O(log n)/. Delete and find the minimal element.
--
-- > deleteFindMin set = (findMin set, deleteMin set)

deleteFindMin :: Set a -> (a,Set a)
deleteFindMin t
  = case t of
      Bin _ x Tip r -> (x,r)
      Bin _ x l r   -> let (xm,l') = deleteFindMin l in (xm,balanceR x l' r)
      Tip           -> (error "Set.deleteFindMin: can not return the minimal element of an empty set", Tip)

-- | /O(log n)/. Delete and find the maximal element.
--
-- > deleteFindMax set = (findMax set, deleteMax set)
deleteFindMax :: Set a -> (a,Set a)
deleteFindMax t
  = case t of
      Bin _ x l Tip -> (x,l)
      Bin _ x l r   -> let (xm,r') = deleteFindMax r in (xm,balanceL x l r')
      Tip           -> (error "Set.deleteFindMax: can not return the maximal element of an empty set", Tip)

-- | /O(log n)/. Retrieves the minimal key of the set, and the set
-- stripped of that element, or 'Nothing' if passed an empty set.
minView :: Set a -> Maybe (a, Set a)
minView Tip = Nothing
minView x = Just (deleteFindMin x)

-- | /O(log n)/. Retrieves the maximal key of the set, and the set
-- stripped of that element, or 'Nothing' if passed an empty set.
maxView :: Set a -> Maybe (a, Set a)
maxView Tip = Nothing
maxView x = Just (deleteFindMax x)

{--------------------------------------------------------------------
  [balance x l r] balances two trees with value x.
  The sizes of the trees should balance after decreasing the
  size of one of them. (a rotation).

  [delta] is the maximal relative difference between the sizes of
          two trees, it corresponds with the [w] in Adams' paper.
  [ratio] is the ratio between an outer and inner sibling of the
          heavier subtree in an unbalanced setting. It determines
          whether a double or single rotation should be performed
          to restore balance. It is correspondes with the inverse
          of $\alpha$ in Adam's article.

  Note that according to the Adam's paper:
  - [delta] should be larger than 4.646 with a [ratio] of 2.
  - [delta] should be larger than 3.745 with a [ratio] of 1.534.

  But the Adam's paper is errorneous:
  - it can be proved that for delta=2 and delta>=5 there does
    not exist any ratio that would work
  - delta=4.5 and ratio=2 does not work

  That leaves two reasonable variants, delta=3 and delta=4,
  both with ratio=2.

  - A lower [delta] leads to a more 'perfectly' balanced tree.
  - A higher [delta] performs less rebalancing.

  In the benchmarks, delta=3 is faster on insert operations,
  and delta=4 has slightly better deletes. As the insert speedup
  is larger, we currently use delta=3.

--------------------------------------------------------------------}
delta,ratio :: Int
delta = 3
ratio = 2

-- The balance function is equivalent to the following:
--
--   balance :: a -> Set a -> Set a -> Set a
--   balance x l r
--     | sizeL + sizeR <= 1   = Bin sizeX x l r
--     | sizeR > delta*sizeL  = rotateL x l r
--     | sizeL > delta*sizeR  = rotateR x l r
--     | otherwise            = Bin sizeX x l r
--     where
--       sizeL = size l
--       sizeR = size r
--       sizeX = sizeL + sizeR + 1
--
--   rotateL :: a -> Set a -> Set a -> Set a
--   rotateL x l r@(Bin _ _ ly ry) | size ly < ratio*size ry = singleL x l r
--                                 | otherwise               = doubleL x l r
--   rotateR :: a -> Set a -> Set a -> Set a
--   rotateR x l@(Bin _ _ ly ry) r | size ry < ratio*size ly = singleR x l r
--                                 | otherwise               = doubleR x l r
--
--   singleL, singleR :: a -> Set a -> Set a -> Set a
--   singleL x1 t1 (Bin _ x2 t2 t3)  = bin x2 (bin x1 t1 t2) t3
--   singleR x1 (Bin _ x2 t1 t2) t3  = bin x2 t1 (bin x1 t2 t3)
--
--   doubleL, doubleR :: a -> Set a -> Set a -> Set a
--   doubleL x1 t1 (Bin _ x2 (Bin _ x3 t2 t3) t4) = bin x3 (bin x1 t1 t2) (bin x2 t3 t4)
--   doubleR x1 (Bin _ x2 t1 (Bin _ x3 t2 t3)) t4 = bin x3 (bin x2 t1 t2) (bin x1 t3 t4)
--
-- It is only written in such a way that every node is pattern-matched only once.
--
-- Only balanceL and balanceR are needed at the moment, so balance is not here anymore.
-- In case it is needed, it can be found in Data.Map.

-- Functions balanceL and balanceR are specialised versions of balance.
-- balanceL only checks whether the left subtree is too big,
-- balanceR only checks whether the right subtree is too big.

-- balanceL is called when left subtree might have been inserted to or when
-- right subtree might have been deleted from.
balanceL :: a -> Set a -> Set a -> Set a
balanceL x l r = case r of
  Tip -> case l of
           Tip -> Bin 1 x Tip Tip
           (Bin _ _ Tip Tip) -> Bin 2 x l Tip
           (Bin _ lx Tip (Bin _ lrx _ _)) -> Bin 3 lrx (Bin 1 lx Tip Tip) (Bin 1 x Tip Tip)
           (Bin _ lx ll@(Bin _ _ _ _) Tip) -> Bin 3 lx ll (Bin 1 x Tip Tip)
           (Bin ls lx ll@(Bin lls _ _ _) lr@(Bin lrs lrx lrl lrr))
             | lrs < ratio*lls -> Bin (1+ls) lx ll (Bin (1+lrs) x lr Tip)
             | otherwise -> Bin (1+ls) lrx (Bin (1+lls+size lrl) lx ll lrl) (Bin (1+size lrr) x lrr Tip)

  (Bin rs _ _ _) -> case l of
           Tip -> Bin (1+rs) x Tip r

           (Bin ls lx ll lr)
              | ls > delta*rs  -> case (ll, lr) of
                   (Bin lls _ _ _, Bin lrs lrx lrl lrr)
                     | lrs < ratio*lls -> Bin (1+ls+rs) lx ll (Bin (1+rs+lrs) x lr r)
                     | otherwise -> Bin (1+ls+rs) lrx (Bin (1+lls+size lrl) lx ll lrl) (Bin (1+rs+size lrr) x lrr r)
                   (_, _) -> error "Failure in Data.Map.balanceL"
              | otherwise -> Bin (1+ls+rs) x l r
{-# NOINLINE balanceL #-}

-- balanceR is called when right subtree might have been inserted to or when
-- left subtree might have been deleted from.
balanceR :: a -> Set a -> Set a -> Set a
balanceR x l r = case l of
  Tip -> case r of
           Tip -> Bin 1 x Tip Tip
           (Bin _ _ Tip Tip) -> Bin 2 x Tip r
           (Bin _ rx Tip rr@(Bin _ _ _ _)) -> Bin 3 rx (Bin 1 x Tip Tip) rr
           (Bin _ rx (Bin _ rlx _ _) Tip) -> Bin 3 rlx (Bin 1 x Tip Tip) (Bin 1 rx Tip Tip)
           (Bin rs rx rl@(Bin rls rlx rll rlr) rr@(Bin rrs _ _ _))
             | rls < ratio*rrs -> Bin (1+rs) rx (Bin (1+rls) x Tip rl) rr
             | otherwise -> Bin (1+rs) rlx (Bin (1+size rll) x Tip rll) (Bin (1+rrs+size rlr) rx rlr rr)

  (Bin ls _ _ _) -> case r of
           Tip -> Bin (1+ls) x l Tip

           (Bin rs rx rl rr)
              | rs > delta*ls  -> case (rl, rr) of
                   (Bin rls rlx rll rlr, Bin rrs _ _ _)
                     | rls < ratio*rrs -> Bin (1+ls+rs) rx (Bin (1+ls+rls) x l rl) rr
                     | otherwise -> Bin (1+ls+rs) rlx (Bin (1+ls+size rll) x l rll) (Bin (1+rrs+size rlr) rx rlr rr)
                   (_, _) -> error "Failure in Data.Map.balanceR"
              | otherwise -> Bin (1+ls+rs) x l r
{-# NOINLINE balanceR #-}

{--------------------------------------------------------------------
  The bin constructor maintains the size of the tree
--------------------------------------------------------------------}
bin :: a -> Set a -> Set a -> Set a
bin x l r
  = Bin (size l + size r + 1) x l r
{-# INLINE bin #-}


{--------------------------------------------------------------------
  Utilities
--------------------------------------------------------------------}

-- | /O(1)/.  Decompose a set into pieces based on the structure of the underlying
-- tree.  This function is useful for consuming a set in parallel.
--
-- No guarantee is made as to the sizes of the pieces; an internal, but
-- deterministic process determines this.  However, it is guaranteed that the pieces
-- returned will be in ascending order (all elements in the first subset less than all
-- elements in the second, and so on).
--
-- Examples:
--
-- > splitRoot (fromList [1..6]) ==
-- >   [fromList [1,2,3],fromList [4],fromList [5,6]]
--
-- > splitRoot empty == []
--
--  Note that the current implementation does not return more than three subsets,
--  but you should not depend on this behaviour because it can change in the
--  future without notice.
splitRoot :: Set a -> [Set a]
splitRoot orig =
  case orig of
    Tip           -> []
    Bin _ v l r -> [l, singleton v, r]
{-# INLINE splitRoot #-}


{--------------------------------------------------------------------
  Debugging
--------------------------------------------------------------------}
-- | /O(n)/. Show the tree that implements the set. The tree is shown
-- in a compressed, hanging format.
showTree :: Show a => Set a -> String
showTree s
  = showTreeWith True False s


{- | /O(n)/. The expression (@showTreeWith hang wide map@) shows
 the tree that implements the set. If @hang@ is
 @True@, a /hanging/ tree is shown otherwise a rotated tree is shown. If
 @wide@ is 'True', an extra wide version is shown.

> Set> putStrLn $ showTreeWith True False $ fromDistinctAscList [1..5]
> 4
> +--2
> |  +--1
> |  +--3
> +--5
>
> Set> putStrLn $ showTreeWith True True $ fromDistinctAscList [1..5]
> 4
> |
> +--2
> |  |
> |  +--1
> |  |
> |  +--3
> |
> +--5
>
> Set> putStrLn $ showTreeWith False True $ fromDistinctAscList [1..5]
> +--5
> |
> 4
> |
> |  +--3
> |  |
> +--2
>    |
>    +--1

-}
showTreeWith :: Show a => Bool -> Bool -> Set a -> String
showTreeWith hang wide t
  | hang      = (showsTreeHang wide [] t) ""
  | otherwise = (showsTree wide [] [] t) ""

showsTree :: Show a => Bool -> [String] -> [String] -> Set a -> ShowS
showsTree wide lbars rbars t
  = case t of
      Tip -> showsBars lbars . showString "|\n"
      Bin _ x Tip Tip
          -> showsBars lbars . shows x . showString "\n"
      Bin _ x l r
          -> showsTree wide (withBar rbars) (withEmpty rbars) r .
             showWide wide rbars .
             showsBars lbars . shows x . showString "\n" .
             showWide wide lbars .
             showsTree wide (withEmpty lbars) (withBar lbars) l

showsTreeHang :: Show a => Bool -> [String] -> Set a -> ShowS
showsTreeHang wide bars t
  = case t of
      Tip -> showsBars bars . showString "|\n"
      Bin _ x Tip Tip
          -> showsBars bars . shows x . showString "\n"
      Bin _ x l r
          -> showsBars bars . shows x . showString "\n" .
             showWide wide bars .
             showsTreeHang wide (withBar bars) l .
             showWide wide bars .
             showsTreeHang wide (withEmpty bars) r

showWide :: Bool -> [String] -> String -> String
showWide wide bars
  | wide      = showString (concat (reverse bars)) . showString "|\n"
  | otherwise = id

showsBars :: [String] -> ShowS
showsBars bars
  = case bars of
      [] -> id
      _  -> showString (concat (reverse (tail bars))) . showString node

node :: String
node           = "+--"

withBar, withEmpty :: [String] -> [String]
withBar bars   = "|  ":bars
withEmpty bars = "   ":bars

{--------------------------------------------------------------------
  Assertions
--------------------------------------------------------------------}
-- | /O(n)/. Test if the internal set structure is valid.
valid :: Ord a => Set a -> Bool
valid t
  = balanced t && ordered t && validsize t

ordered :: Ord a => Set a -> Bool
ordered t
  = bounded (const True) (const True) t
  where
    bounded lo hi t'
      = case t' of
          Tip         -> True
          Bin _ x l r -> (lo x) && (hi x) && bounded lo (<x) l && bounded (>x) hi r

balanced :: Set a -> Bool
balanced t
  = case t of
      Tip         -> True
      Bin _ _ l r -> (size l + size r <= 1 || (size l <= delta*size r && size r <= delta*size l)) &&
                     balanced l && balanced r

validsize :: Set a -> Bool
validsize t
  = (realsize t == Just (size t))
  where
    realsize t'
      = case t' of
          Tip          -> Just 0
          Bin sz _ l r -> case (realsize l,realsize r) of
                            (Just n,Just m)  | n+m+1 == sz  -> Just sz
                            _                -> Nothing
