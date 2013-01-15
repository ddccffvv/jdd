{-# LANGUAGE OverloadedStrings
           , RecordWildCards
  #-}

module Jimple where

import qualified Data.ByteString.Char8 as B

import Debug.Trace

import Data.Bits
import Data.Char
import Data.Maybe
import Data.Ord

import Numeric

import qualified Data.Foldable as F
import qualified Data.Map      as M
import qualified Data.List     as L

import Text.Parsec.ByteString
import Text.Parsec.Char
import Text.Parsec.Combinator
import Text.Parsec as P

import Control.Monad
import Control.Monad.State as ST
import Control.Monad.Reader as R
import Control.Applicative

import qualified Parser as CF

import Util
import Jimple.Types
import Jimple.Exceptions


typeP :: Parser Type
typeP = try $ do
  tag <- anyChar
  case tag of
    'B' -> return T_byte
    'C' -> return T_char
    'D' -> return T_double
    'F' -> return T_float
    'I' -> return T_int
    'J' -> return T_long
    'S' -> return T_short
    'Z' -> return T_boolean
    'V' -> return T_void
    'L' -> T_object . B.pack <$> anyChar `manyTill` char ';'
    '[' -> do
      dims <- length <$> option [] (many1 $ char '[')
      T_array (dims + 1) <$> typeP
    _   -> fail $ "Unknown type tag: " ++ show tag

methodTypeP :: Parser ([Type], Type)
methodTypeP = do
  params <- P.between (char '(') (char ')') $ P.optionMaybe $ P.many typeP
  result <- typeP
  return (fromMaybe [] params, result)


methodTypeFromBS :: B.ByteString -> Either ParseError ([Type], Type)
methodTypeFromBS = runP methodTypeP () "typesFromBS"

methodTypeFromBS' :: B.ByteString -> ([Type], Type)
methodTypeFromBS' = either (error.show) id . methodTypeFromBS

typeFromBS :: B.ByteString -> Either ParseError Type
typeFromBS = runP typeP () "typeFromBS"

typeFromBS' :: B.ByteString -> Type
typeFromBS' = either (const T_unknown) id . typeFromBS


methodSigP :: ([Type] -> Type -> MethodSignature) -> Parser MethodSignature
methodSigP meth = liftM2 meth paramsP resultP
  where
    paramsP = between (char '(') (char ')') $ P.many $ try typeP
    resultP = choice [try typeP, try voidP]
    voidP = char 'V' >> return T_void

methodSigFromBS bs meth = runP (methodSigP meth) () "methodSig" bs

methodSigFromBS' bs meth = either (error $ "methodSig: " ++ show bs) id $
                     methodSigFromBS bs meth


bytesToUnsigned :: String -> Integer
bytesToUnsigned = L.foldl' (\n b -> n * 256 + fromIntegral (ord b)) 0


exceptionTableM = do
  size <- u2
  entries <- replicateM (fromIntegral size) entry
  return $ ExceptTable entries
  where
    u2 = bytesToUnsigned <$> count 2 anyToken
    entry = do
      (from, to) <- liftM2 (,) u2 u2
      target <- u2
      eid <- u2
      return $ ExceptEntry from to target eid


data JimpleST = JimpleST { jimpleFree  :: [Variable Value]
                         , jimpleStack :: [Variable Value]
                         , thisPos     :: Integer
                         , prevPos     :: Integer
                         }

byteCodeP excTable codeLength = do
  ST.modify $ \(m, j) -> (m, j { thisPos = 0, prevPos = 0 })
  codeM

  where
    codeM = do
      pos <- ST.gets $ thisPos . snd
      modifySnd $ \j -> j { prevPos = pos }

      -- Handle try
      F.forM_ (fromStart  excTable pos) $ \exc ->
        append $ S_try (pos, exceptTo exc)

      -- Handle catch
      F.forM_ (fromTarget excTable pos) catch

      unless (pos >= codeLength) $ do
        mcode <- optionMaybe nextByte
        when (isJust mcode) $ do
          parse $ ord $ fromJust mcode
          codeM

    catch (ExceptEntry start to _ eid) = do
      mx <- if eid == 0 then return Nothing else getCP eid
      let x = (\(CF.ClassRef x) -> x) `fmap` mx
      append $ S_catch (start, to) x
      void $ pushL $! VarLocal $! Local "exc"


    parse code = case code of
      -- NOP: needed to maintain correct line count for goto
      0x00 -> append S_nop

      -- ACONST_NULL: @null@
      0x01 -> void $ push $! VConst C_null

      -- ICONST_#: constants -1 to 5
      _ | code `elem` [0x02..0x08] ->
        void $ push $! VConst $! C_int $! fromIntegral $! code - 3

      -- LCONST_#: long constants 0L to 1L
      0x09 -> void $ push $! VConst $! C_long 0
      0x0a -> void $ push $! VConst $! C_long 1

      -- FCONST_#: float constants 0.0f to 2.0f
      _ | code `elem` [0x0b, 0x0c, 0x0d] ->
        void $ push $! VConst $! C_float $! fromIntegral $! code - 0x0b

      -- DCONST_#: double constants 0.0 to 1.0
      0x0e -> void $ push $! VConst $! C_double 0.0
      0x0f -> void $ push $! VConst $! C_double 1.0

      -- BIPUSH: signed byte to stack as int
      0x10 -> void . push =<< VConst . C_int <$> s1

      -- SIPUSH: signed short to stack as int
      0x11 -> void . push =<< VConst . C_int <$> s2

      -- LDC#: push from constant pool (String, int, float) + wide / double
      -- TODO: Add support for other types than String (Str)
      0x12 -> do Just cpC <- askCP1
                 void $ push $! cpToVC cpC
      0x13 -> do Just cpC <- askCP2
                 void $ push $! cpToVC cpC
      0x14 -> do Just cpC <- askCP2
                 void $ push $! cpToVC cpC

      -- ?LOAD: load value from local variable, int to object ref
      _ | code `elem` [0x15..0x19] -> void . pushL =<< getLocal <$> u1

      -- ?LOAD_#: int to object ref value from local variable 0 to 3
      _ | code `elem` [0x1a..0x2d] -> void $ pushL $! getLocal var
        where
          val = code - 0x1a
          var = val `mod` 4
          tpe = types !! (val `div` 4) -- int to object ref

      -- ?ALOAD: array retrieval, int to short
      _ | code `elem` [0x2e..0x35] -> arrayGet $ types !! (code - 0x2e)

      -- ?STORE: store value in local variable #, int to object ref
      _ | code `elem` [0x36..0x3a] -> do
        var <- u1
        append =<< S_assign (getLocal var) . VLocal <$> pop


      -- ?STORE_#: store int value from stack in local variable 0 to 3
      _ | code `elem` [0x3b..0x4e] ->
        append =<< S_assign (getLocal var) . VLocal <$> pop
        where
          val = code - 0x3b
          var = val `mod` 4
          tpe = types !! (val `div` 4) -- int to object ref

      -- ?ASTORE: array assignment, int to short
      _ | code `elem` [0x4f..0x56] -> arraySet $ types !! (code - 0x4f)

      -- POP and POP2
      0x57 -> void pop
      0x58 -> replicateM_ 2 pop

      -- DUP: a -> a, a
      0x59 -> mapM_ pushL =<< replicate 2 <$> pop

      -- DUP_x1: b, a -> a, b, a
      0x5a -> do (a, b) <- liftM2 (,) pop pop
                 mapM_ pushL [a, b, a]

      -- TODO: Alternative forms
      -- DUP_x2: c, b, a -> a, c, b, a
      0x5b -> do (a, b, c) <- liftM3 (,,) pop pop pop
                 mapM_ pushL [a, c, b, a]

      -- DUP2: b, a -> b, a, b, a
      0x5c -> do (a, b) <- liftM2 (,) pop pop
                 mapM_ pushL [b, a, b, a]

      -- DUP2_x1: c, b, a -> b, a, c, b, a
      0x5d -> do (a, b, c) <- liftM3 (,,) pop pop pop
                 mapM_ pushL [b, a, c, b, a]

      -- DUP2_x2: d, c, b, a -> b, a, d, c, b, a
      0x5e -> do (a, b, c, d) <- liftM4 (,,,) pop pop pop pop
                 mapM_ pushL [b, a, d, c, b, a]

      -- SWAP: a, b -> b, a
      0x5f -> mapM_ pushL =<< replicateM 2 pop

      -- IADD: add two ints
      0x60 -> void $ push =<< VExpr <$> apply2 E_add

      -- ISUB: sub two ints
      0x64 -> void $ push =<< VExpr <$> apply2 E_sub

      -- IMUL: multiply two ints
      0x68 -> void $ push =<< VExpr <$> apply2 E_mul

      -- IREM: rem two ints
      0x70 -> void $ push =<< VExpr <$> apply2 E_rem

      -- IAND: and two ints
      0x7e -> void $ push =<< VExpr <$> apply2 E_and

      -- IINC: increment by constant
      0x84 -> do (idx, val) <- liftM2 (,) u1 s1
                 append $! S_assign (getLocal idx) $! VExpr $!
                   E_add (VLocal $! getLocal idx) $! VConst $! C_int val

      -- ?2?: convert types
      _ | code `elem` [0x85..0x93] ->
        void $ push . VLocal =<< pop

      -- IF??: int cmp with zero, eq to le
      _ | code `elem` [0x99..0x9e] ->
        ifz $[E_eq, E_ne, E_lt, E_ge, E_gt, E_le] !! (code - 0x99)

      -- IF_ICMP??: int cmp, eq to le
      _ | code `elem` [0x9f..0xa4] ->
        if2 $ [E_eq, E_ne, E_lt, E_ge, E_gt, E_le] !! (code - 0x9f)

      -- GOTO: unconditional jump
      0xa7 -> append =<< S_goto <$> label2

      -- LOOKUPSWITCH: switch statement
      0xab -> do
        -- get value for switching
        v <- popI
        -- skip padding
        pos <- fromIntegral <$> thisPos <$> ST.gets snd
        let off = pos `mod` 4
        when (off > 0) $
          replicateM_ (4 - off) u1
        -- address for default code
        defaultByte <- Label <$> s4
        -- match-pairs and their addresses
        npairs <- fromIntegral <$> s4
        pairs <- replicateM npairs $ liftM2 (,) s4 (Label <$> s4)
        -- build lookupSwitch
        append $! S_lookupSwitch v defaultByte $ L.sortBy (comparing snd) pairs

      -- IRETURN: return int value from stack
      0xac -> append =<< S_return . Just . VLocal <$> pop

      -- ARETURN: return object ref from stack
      0xb0 -> append =<< S_return . Just . VLocal <$> pop

      -- RETURN: return void
      0xb1 -> append $ S_return Nothing

      -- GETSTATIC: get static field
      0xb2 -> do
        Just (CF.FieldRef cs desc) <- askCP2
        void $ push $! VLocal $! VarRef $! R_staticField cs desc

      -- GETFIELD: get instance field
      0xb4 -> do
        Just (CF.FieldRef cs desc) <- askCP2
        obj <- popI
        void $ push $! VLocal $! VarRef $! R_instanceField obj desc

      -- PUTFIELD: get instance field
      0xb5 -> do
        Just (CF.FieldRef cs desc) <- askCP2
        (val, obj) <- liftM2 (,) pop popI
        append $! S_assign (VarRef $! R_instanceField obj desc) $!
                  VLocal val

      -- INVOKEVIRTUAL: invoke instance method on object ref
      0xb6 -> do method <- methodP
                 params <- replicateM (length $ methodParams method) popI
                 objRef <- popI
                 v      <- resultVar method
                 append $! S_assign v $ VExpr $
                           E_invoke (I_virtual objRef) method params

      -- INVOKESPECIAL: invoke instance method on object ref
      0xb7 -> do method <- methodP
                 params <- replicateM (length $ methodParams method) popI
                 objRef <- popI
                 v      <- resultVar method
                 append $! S_assign v $ VExpr $
                           E_invoke (I_special objRef) method params

      -- INVOKESTATIC: invoke a static method (no object ref)
      0xb8 -> do method <- methodP
                 params <- replicateM (length $ methodParams method) popI
                 v      <- resultVar method
                 append $! S_assign v $ VExpr $
                           E_invoke I_static method params

      -- ATHROW: throw an exception
      0xbf -> do v <- popI
                 append $ S_throw v

      -- NEW: new object ref
      0xbb -> do Just (CF.ClassRef path) <- askCP2
                 void $ push $! VExpr $! E_new (R_object path) []

      -- NEWARRAY: new array of primitive type
      0xbc -> do tpe   <- fromIntegral <$> u1
                 count <- popI
                 void $ push $ VExpr $! E_newArray (atypes !! (tpe - 4)) count

      -- ARRAYLENGTH: get length of array ref
      0xbe -> void . push =<< VExpr . E_length <$> popI

      -- CHECKCAST: cast an object to type
      0xc0 -> do Just (CF.ClassRef (CF.Class path)) <- askCP2
                 obj <- popI
                 void $ push $ VExpr $! E_cast (T_object path) obj

      -- IFNULL: if value is null jump
      0xc6 -> do v <- popI
                 append =<< S_if (E_eq v $ VConst C_null) <$> label2

      -- IFNONNULL: if value is null jump
      0xc7 -> do v <- popI
                 append =<< S_if (E_ne v $ VConst C_null) <$> label2

      -- UNASSIGNED: skip (can appear after last return; garbage)
      _ | code `elem` [0xcb..0xfd] -> return ()

      -- NOT IMPLEMENTED: my head just exploded
      _ -> error $ "Unknown code: 0x" ++ showHex code ""


    getLocal idx = VarLocal $! Local $! 'l' : show idx

    -- pop a value from the stack (return first stack variable)
    pop = do
      (x:xs) <- ST.gets $ jimpleStack . snd
      modifySnd $ \j -> j { jimpleStack = xs }
      return x

    -- pop as immediate value
    popI = VLocal <$> pop

    -- get free stack variable
    getFree = do
      (x:xs) <- ST.gets $ jimpleFree . snd
      modifySnd $ \j -> j { jimpleStack = x : jimpleStack j
                          , jimpleFree  = xs                }
      return x

    -- push value to stack (assign to next stack variable)
    push v = do
      x <- getFree
      append $! S_assign x v
      return x

    -- push a local variable to stack
    pushL = push . VLocal

    -- append a label-less statement to code
    append cmd = do
      pos <- ST.gets $ prevPos . snd
      modifyFst $ \m ->
        m { methodStmts = methodStmts m ++ [(Just $ Label pos, cmd)] }

    -- read and register 1 byte
    nextByte = do b <- anyChar
                  modifySnd $ \j -> j { thisPos = 1 + thisPos j }
                  return b

    -- read 1-byte int
    u1 = (fromIntegral . ord) <$> nextByte

    -- read 2-byte int
    u2 = bytesToUnsigned <$> count 2 nextByte

    -- read 4-byte int
    u4 = bytesToUnsigned <$> count 4 nextByte

    -- read 1-byte signed int
    s1 = CF.makeSigned  8 <$> u1

    -- read 2-byte signed int
    s2 = CF.makeSigned 16 <$> u2

    -- read 4-byte signed int
    s4 = CF.makeSigned 32 <$> u4

    -- read 2-byte label (signed short)
    label2 = Label <$> s2

    -- retrieve an element from the constant pool
    getCP u = M.lookup u <$> R.asks CF.classConstants
    askCP u = liftM2 M.lookup u $ R.asks CF.classConstants
    askCP1 = askCP u1
    askCP2 = askCP u2

    -- read a method description from constant pool
    methodP = do
      Just (CF.Method path (CF.Desc name tpe)) <- askCP2
      return $! methodSigFromBS' tpe $! MethodSig path name []

    -- apply operator to stack vars
    apply1 op = liftM op popI
    apply2 op = liftM2 (flip op) popI popI

    -- general version of if for cmp with zero
    ifz op = append =<< liftM2 S_if (apply1 $ flip op $ VConst $ C_int 0) label2

    -- general version of if for binary op
    if2 op = append =<< liftM2 S_if (apply2 op) label2

    -- array retrieval
    arrayGet tpe =
      void . push =<< VLocal . VarRef <$> apply2 R_array

    -- array retrieval
    arraySet tpe = do
      var <- VLocal <$> pop
      ref <- VarRef <$> apply2 R_array
      append $ S_assign ref var


    -- allocate new variable for result of method call unless it's void
    resultVar m | methodResult m == T_void = return $ VarLocal $ Local "_"
                | otherwise                = getFree

    -- Convert constant pool value to VConst
    cpToVC (CF.Str s) = VConst $! C_string s
    cpToVC a = error $ "Unknown constant: " ++ show a

    types = [ T_int,       T_long,    T_float, T_double
            , T_object "", T_boolean, T_char,  T_short  ]

    atypes = [ T_boolean,  T_char  , T_float, T_double
             , T_byte   ,  T_short , T_int  , T_long   ]

parseJimple :: CF.ClassFile -> B.ByteString -> (Maybe ParseError, JimpleMethod Value)
parseJimple cf method
  | hasCode   = go $! ST.runState (R.runReaderT goM cf) (emptyMethod, emptyState)
  | otherwise = (Nothing, emptyMethod)
  where
    emptyMethod = Method   sig [] [] [] []
    emptyState  = JimpleST stackVars [] 0 0

    stackVars = map (VarLocal . Local . ("s"++) . show) [1..]

    go (Left err, (meth, jst)) = (Just err, meth)
    go (Right _,  (meth, jst)) = (Nothing,  meth)

    CF.AttrBlock{..} = CF.classMethods cf M.! method
    bytes = blockAttrs M.! "Code"
    hasCode = "Code" `M.member` blockAttrs

    goM = do
      let MethodSig _ _ _ vs r = methodSigFromBS' blockDesc $
                                 MethodSig (CF.Class "") blockDesc []
      modifyFst $ \m -> m { methodLocalDecls = zipWith decl vs ns }
      -- Add reference to this from "l0" when method is not static
      unless isStatic $
        modifyFst $ \m -> m {
          methodStmts =
             [(Nothing,
               S_assign (VarLocal $ Local "l0") (VLocal $ VarRef R_this))]
          }

      let dropSize = 4  -- maxStack and maxLocals

      -- Extract codeLength and then codeBytes
      let codeLengthM = do
            _ <- count dropSize anyToken  -- maxStack, maxLocals
            bytesToUnsigned <$> count 4 anyToken
      let codeLength = either (error.show) id $
                       runP codeLengthM () "codeSize" bytes
      let (codeBytes, rest) = B.splitAt (fromIntegral codeLength) $
                              B.drop (dropSize + 4) bytes

      -- Extract exception table
      let excTable = cleanupExcTable $
                     either (error.show) id $
                     runP exceptionTableM () "exceptionTable" rest

      -- code <- runP (count codeSize anyChar)
      runPT (byteCodeP excTable codeLength) () "" codeBytes

    decl t n = LocalDecl t $ Local $ 'l' : show n

    ns = if isStatic then [0..] else [1..]
    isStatic = F_static `elem` accFlags

    sig = MethodSig (CF.unClassRef $ CF.classThis cf) name accFlags params result

    name = blockName
    (params, result) = methodTypeFromBS' blockDesc

    accFlags = getFlags blockFlags

getFlags blockFlags = [ flag | (i, flag) <- flags, blockFlags `testBit` i ]
  where
    flags = [ ( 0, F_public)
            , ( 1, F_private)
            , ( 2, F_protected)
            , ( 3, F_static)
            , ( 4, F_final)
            , ( 5, F_synchronized)
            , ( 6, F_bridge)
            , ( 7, F_varargs)
            , ( 8, F_native)
              -- gap
            , (10, F_abstract)
            , (11, F_strict)
            , (12, F_synthetic)
            ]