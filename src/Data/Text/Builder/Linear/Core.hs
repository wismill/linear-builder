-- |
-- Copyright:   (c) 2022 Andrew Lelechenko
-- Licence:     BSD3
-- Maintainer:  Andrew Lelechenko <andrew.lelechenko@gmail.com>
--
-- Low-level routines for 'Buffer' manipulations.
module Data.Text.Builder.Linear.Core (
  Buffer,
  runBuffer,
  runBufferBS,
  dupBuffer,
  consumeBuffer,
  eraseBuffer,
  byteSizeOfBuffer,
  lengthOfBuffer,
  dropBuffer,
  takeBuffer,
  appendBounded,
  appendExact,
  prependBounded,
  prependExact,
  (><),
) where

import Data.ByteString.Internal (ByteString (..))
import Data.Text qualified as T
import Data.Text.Array qualified as A
import Data.Text.Internal (Text (..))
import GHC.Exts (Int (..), Levity (..), RuntimeRep (..), TYPE, byteArrayContents#, isByteArrayPinned#, isTrue#, plusAddr#, sizeofByteArray#, unsafeCoerce#)
import GHC.ForeignPtr (ForeignPtr (..), ForeignPtrContents (..))
import GHC.ST (ST (..), runST)

-- | Internally 'Buffer' is a mutable buffer.
-- If a client gets hold of a variable of type 'Buffer',
-- they'd be able to pass a mutable buffer to concurrent threads.
-- That's why API below is carefully designed to prevent such possibility:
-- clients always work with linear functions 'Buffer' ⊸ 'Buffer' instead
-- and run them on an empty 'Buffer' to extract results.
--
-- In terms of [@linear-base@](https://hackage.haskell.org/package/linear-base)
-- 'Buffer' is [@Consumable@](https://hackage.haskell.org/package/linear-base/docs/Prelude-Linear.html#t:Consumable)
-- (see 'consumeBuffer')
-- and [@Dupable@](https://hackage.haskell.org/package/linear-base/docs/Prelude-Linear.html#t:Dupable)
-- (see 'dupBuffer'),
-- but not [@Movable@](https://hackage.haskell.org/package/linear-base/docs/Prelude-Linear.html#t:Movable).
--
-- >>> :set -XOverloadedStrings -XLinearTypes
-- >>> import Data.Text.Builder.Linear.Buffer
-- >>> runBuffer (\b -> '!' .<| "foo" <| (b |> "bar" |>. '.'))
-- "!foobar."
--
-- Remember: this is a strict builder, so on contrary to "Data.Text.Lazy.Builder"
-- for optimal performance you should use strict left folds instead of lazy right ones.
--
-- 'Buffer' is an unlifted datatype,
-- so you can put it into an unboxed tuple @(# ..., ... #)@,
-- but not into @(..., ...)@.
data Buffer ∷ TYPE ('BoxedRep 'Unlifted) where
  Buffer ∷ {-# UNPACK #-} !Text → Buffer

-- | Unwrap 'Buffer', no-op.
-- Most likely, this is not the function you're looking for
-- and you need 'runBuffer' instead.
unBuffer ∷ Buffer ⊸ Text
unBuffer (Buffer x) = x

-- | Run a linear function on an empty 'Buffer', producing a strict 'Text'.
--
-- Be careful to write @runBuffer (\b -> ...)@ instead of @runBuffer $ \b -> ...@,
-- because current implementation of linear types lacks special support for '($)'.
-- Another option is to enable @{-# LANGUAGE BlockArguments #-}@
-- and write @runBuffer \b -> ...@.
-- Alternatively, you can import
-- [@($)@](https://hackage.haskell.org/package/linear-base/docs/Prelude-Linear.html#v:-36-)
-- from [@linear-base@](https://hackage.haskell.org/package/linear-base).
--
-- 'runBuffer' is similar in spirit to mutable arrays API in
-- [@Data.Array.Mutable.Linear@](https://hackage.haskell.org/package/linear-base/docs/Data-Array-Mutable-Linear.html),
-- which provides functions like
-- [@fromList@](https://hackage.haskell.org/package/linear-base/docs/Data-Array-Mutable-Linear.html#v:fromList) ∷ [@a@] → (@Vector@ @a@ ⊸ [@Ur@](https://hackage.haskell.org/package/linear-base-0.3.0/docs/Prelude-Linear.html#t:Ur) b) ⊸ [@Ur@](https://hackage.haskell.org/package/linear-base-0.3.0/docs/Prelude-Linear.html#t:Ur) @b@.
-- Here the initial buffer is always empty and @b@ is 'Text'. Since 'Text' is
-- [@Movable@](https://hackage.haskell.org/package/linear-base/docs/Prelude-Linear.html#t:Movable),
-- 'Text' and [@Ur@](https://hackage.haskell.org/package/linear-base-0.3.0/docs/Prelude-Linear.html#t:Ur) 'Text' are equivalent.
runBuffer ∷ (Buffer ⊸ Buffer) ⊸ Text
runBuffer f = unBuffer (shrinkBuffer (f (Buffer mempty)))

-- | Same as 'runBuffer', but returning a UTF-8 encoded strict 'ByteString'.
runBufferBS ∷ (Buffer ⊸ Buffer) ⊸ ByteString
runBufferBS f = case shrinkBuffer (f (Buffer memptyPinned)) of
  Buffer (Text (A.ByteArray arr) (I# from) len) → BS fp len
    where
      addr# = byteArrayContents# arr `plusAddr#` from
      fp = ForeignPtr addr# (PlainPtr (unsafeCoerce# arr))

shrinkBuffer ∷ Buffer ⊸ Buffer
shrinkBuffer (Buffer (Text arr from len)) = Buffer $ runST $ do
  arrM ← unsafeThaw arr
  A.shrinkM arrM (from + len)
  arr' ← A.unsafeFreeze arrM
  pure $ Text arr' from len

memptyPinned ∷ Text
memptyPinned = runST $ do
  marr ← A.newPinned 0
  arr ← A.unsafeFreeze marr
  pure $ Text arr 0 0

-- | Duplicate builder. Feel free to process results in parallel threads.
-- Similar to
-- [@Dupable@](https://hackage.haskell.org/package/linear-base/docs/Prelude-Linear.html#t:Dupable)
-- from [@linear-base@](https://hackage.haskell.org/package/linear-base).
--
-- It is a bit tricky to use because of
-- <https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/linear_types.html#limitations current limitations>
-- of linear types with regards to @let@ and @where@. E. g., one cannot write
--
-- > let (# b1, b2 #) = dupBuffer b in ("foo" <| b1) >< (b2 |> "bar")
--
-- Instead write:
--
-- >>> :set -XOverloadedStrings -XLinearTypes -XUnboxedTuples
-- >>> import Data.Text.Builder.Linear.Buffer
-- >>> runBuffer (\b -> (\(# b1, b2 #) -> ("foo" <| b1) >< (b2 |> "bar")) (dupBuffer b))
-- "foobar"
--
-- Note the unboxed tuple: 'Buffer' is an unlifted datatype,
-- so it cannot be put into @(..., ...)@.
dupBuffer ∷ Buffer ⊸ (# Buffer, Buffer #)
dupBuffer (Buffer x) = (# Buffer x, Buffer (T.copy x) #)

-- | Consume buffer linearly,
-- similar to
-- [@Consumable@](https://hackage.haskell.org/package/linear-base/docs/Prelude-Linear.html#t:Consumable)
-- from [@linear-base@](https://hackage.haskell.org/package/linear-base).
consumeBuffer ∷ Buffer ⊸ ()
consumeBuffer Buffer {} = ()

-- | Erase buffer's content, replacing it with an empty 'Text'.
eraseBuffer ∷ Buffer ⊸ Buffer
eraseBuffer (Buffer (Text arr _ _)) =
  Buffer (if isPinned arr then memptyPinned else mempty)

-- | Return buffer's size in __bytes__ (not in 'Char's).
-- This could be useful to implement a lazy builder atop of a strict one.
byteSizeOfBuffer ∷ Buffer ⊸ (# Buffer, Word #)
byteSizeOfBuffer (Buffer t@(Text _ _ len)) = (# Buffer t, fromIntegral len #)

-- | Return buffer's length in 'Char's (not in bytes).
-- This could be useful to implement @dropEndBuffer@ and @takeEndBuffer@, e. g.,
--
-- @
-- import Data.Unrestricted.Linear
--
-- dropEndBuffer :: Word -> Buffer %1 -> Buffer
-- dropEndBuffer n buf =
--   (\(# buf', len #) -> case move len of Ur len' -> takeBuffer (len' - n) buf')
--     (lengthOfBuffer buf)
-- @
lengthOfBuffer ∷ Buffer ⊸ (# Buffer, Word #)
lengthOfBuffer (Buffer t) = (# Buffer t, fromIntegral (T.length t) #)

-- | Slice 'Buffer' by dropping given number of 'Char's.
dropBuffer ∷ Word → Buffer ⊸ Buffer
dropBuffer nChar (Buffer t@(Text arr off len))
  | nByte <= 0 = Buffer (Text arr (off + len) 0)
  | otherwise = Buffer (Text arr (off + nByte) (len - nByte))
  where
    nByte = T.measureOff (fromIntegral nChar) t

-- | Slice 'Buffer' by taking given number of 'Char's.
takeBuffer ∷ Word → Buffer ⊸ Buffer
takeBuffer nChar (Buffer t@(Text arr off _))
  | nByte <= 0 = Buffer t
  | otherwise = Buffer (Text arr off nByte)
  where
    nByte = T.measureOff (fromIntegral nChar) t

-- | Low-level routine to append data of unknown size to a 'Buffer'.
appendBounded
  ∷ Int
  -- ^ Upper bound for the number of bytes, written by an action
  → (∀ s. A.MArray s → Int → ST s Int)
  -- ^ Action, which writes bytes __starting__ from the given offset
  -- and returns an actual number of bytes written.
  → Buffer
  ⊸ Buffer
appendBounded maxSrcLen appender (Buffer (Text dst dstOff dstLen)) = Buffer $ runST $ do
  let dstFullLen = sizeofByteArray dst
      newFullLen = dstOff + 2 * (dstLen + maxSrcLen)
  newM ←
    if dstOff + dstLen + maxSrcLen <= dstFullLen
      then unsafeThaw dst
      else do
        tmpM ← (if isPinned dst then A.newPinned else A.new) newFullLen
        A.copyI dstLen tmpM dstOff dst dstOff
        pure tmpM
  srcLen ← appender newM (dstOff + dstLen)
  new ← A.unsafeFreeze newM
  pure $ Text new dstOff (dstLen + srcLen)
{-# INLINE appendBounded #-}

-- | Low-level routine to append data of known size to a 'Buffer'.
appendExact
  ∷ Int
  -- ^ Exact number of bytes, written by an action
  → (∀ s. A.MArray s → Int → ST s ())
  -- ^ Action, which writes bytes __starting__ from the given offset
  → Buffer
  ⊸ Buffer
appendExact srcLen appender =
  appendBounded
    srcLen
    (\dst dstOff → appender dst dstOff >> pure srcLen)
{-# INLINE appendExact #-}

-- | Low-level routine to prepend data of unknown size to a 'Buffer'.
prependBounded
  ∷ Int
  -- ^ Upper bound for the number of bytes, written by an action
  → (∀ s. A.MArray s → Int → ST s Int)
  -- ^ Action, which writes bytes __finishing__ before the given offset
  -- and returns an actual number of bytes written.
  → (∀ s. A.MArray s → Int → ST s Int)
  -- ^ Action, which writes bytes __starting__ from the given offset
  -- and returns an actual number of bytes written.
  → Buffer
  ⊸ Buffer
prependBounded maxSrcLen prepender appender (Buffer (Text dst dstOff dstLen))
  | maxSrcLen <= dstOff = Buffer $ runST $ do
      newM ← unsafeThaw dst
      srcLen ← prepender newM dstOff
      new ← A.unsafeFreeze newM
      pure $ Text new (dstOff - srcLen) (srcLen + dstLen)
  | otherwise = Buffer $ runST $ do
      let dstFullLen = sizeofByteArray dst
          newOff = dstLen + maxSrcLen
          newFullLen = 2 * newOff + (dstFullLen - dstOff - dstLen)
      newM ← (if isPinned dst then A.newPinned else A.new) newFullLen
      srcLen ← appender newM newOff
      A.copyI dstLen newM (newOff + srcLen) dst dstOff
      new ← A.unsafeFreeze newM
      pure $ Text new newOff (dstLen + srcLen)
{-# INLINE prependBounded #-}

-- | Low-level routine to append data of unknown size to a 'Buffer'.
prependExact
  ∷ Int
  -- ^ Exact number of bytes, written by an action
  → (∀ s. A.MArray s → Int → ST s ())
  -- ^ Action, which writes bytes __starting__ from the given offset
  → Buffer
  ⊸ Buffer
prependExact srcLen appender =
  prependBounded
    srcLen
    (\dst dstOff → appender dst (dstOff - srcLen) >> pure srcLen)
    (\dst dstOff → appender dst dstOff >> pure srcLen)
{-# INLINE prependExact #-}

unsafeThaw ∷ A.Array → ST s (A.MArray s)
unsafeThaw (A.ByteArray a) = ST $ \s# →
  (# s#, A.MutableByteArray (unsafeCoerce# a) #)

sizeofByteArray ∷ A.Array → Int
sizeofByteArray (A.ByteArray a) = I# (sizeofByteArray# a)

isPinned ∷ A.Array → Bool
isPinned (A.ByteArray a) = isTrue# (isByteArrayPinned# a)

-- | Concatenate two 'Buffer's, potentially mutating both of them.
--
-- You likely need to use 'dupBuffer' to get hold on two builders at once:
--
-- >>> :set -XOverloadedStrings -XLinearTypes -XUnboxedTuples
-- >>> import Data.Text.Builder.Linear.Buffer
-- >>> runBuffer (\b -> (\(# b1, b2 #) -> ("foo" <| b1) >< (b2 |> "bar")) (dupBuffer b))
-- "foobar"
(><) ∷ Buffer ⊸ Buffer ⊸ Buffer

infix 6 ><
Buffer (Text left leftOff leftLen) >< Buffer (Text right rightOff rightLen) = Buffer $ runST $ do
  let leftFullLen = sizeofByteArray left
      rightFullLen = sizeofByteArray right
      canCopyToLeft = leftOff + leftLen + rightLen <= leftFullLen
      canCopyToRight = leftLen <= rightOff
      shouldCopyToLeft = canCopyToLeft && (not canCopyToRight || leftLen >= rightLen)
  if shouldCopyToLeft
    then do
      newM ← unsafeThaw left
      A.copyI rightLen newM (leftOff + leftLen) right rightOff
      new ← A.unsafeFreeze newM
      pure $ Text new leftOff (leftLen + rightLen)
    else
      if canCopyToRight
        then do
          newM ← unsafeThaw right
          A.copyI leftLen newM (rightOff - leftLen) left leftOff
          new ← A.unsafeFreeze newM
          pure $ Text new (rightOff - leftLen) (leftLen + rightLen)
        else do
          let fullLen = leftOff + leftLen + rightLen + (rightFullLen - rightOff - rightLen)
          newM ← (if isPinned left || isPinned right then A.newPinned else A.new) fullLen
          A.copyI leftLen newM leftOff left leftOff
          A.copyI rightLen newM (leftOff + leftLen) right rightOff
          new ← A.unsafeFreeze newM
          pure $ Text new leftOff (leftLen + rightLen)
