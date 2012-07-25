module Jimple.Types where

import qualified Data.ByteString as B
import qualified Parser as CF

data JimpleMethod = Method
                    { methodLocalDecls :: [LocalDecl]
                    , methodIdentStmts :: [IdentStmt]
                    , methodStmts      :: [(Maybe Label, Stmt)]
                    , methodExcepts    :: [Except] }
                  deriving Show

data IdentStmt = IStmt Local Ref
               deriving Show

data LocalDecl = LocalDecl Type String
               deriving Show

data Except = Except Ref Label Label Label
            deriving Show


data Stmt = S_breakpoint
          | S_assign Variable Value
          | S_enterMonitor Im
          | S_exitMonitor  Im
          | S_goto Label
          | S_if Expression Label   -- Only condition expressions are allowed
          | S_invoke InvokeType MethodSignature [Im] Variable
          | S_lookupSwitch Label [(Int, Label)]
          | S_nop
          | S_ret Local
          | S_return Im
          | S_returnVoid
          | S_tableSwitch Im Label [(Int, Label)]
          | S_throw Im

data Value = VConst Constant
           | VLocal Variable
           | VExpr  Expression

data Label = Label Integer
instance Show Label where show (Label l) = show l

data Im = IConst Constant
        | ILocal Variable


data Local = Local String
instance Show Local where show (Local s) = s


data Constant = C_double Double
              | C_float  Double
              | C_int    Integer
              | C_long   Integer
              | C_string B.ByteString
              | C_null
              deriving Show

data Variable = VarRef Ref | VarLocal Local

data RValue = RV_ref   Ref
            | RV_const Constant
            | RV_expr  Expression
            | RV_local Local
            | RV_nnsa  Integer -- TODO: next_next_statement_address ??
            deriving Show
data Ref = R_caughtException
         | R_parameter     Integer
         | R_this
         | R_array         Im Im
         | R_instanceField Im CF.Desc
         | R_staticField      CF.Desc
         | R_object        CF.Class
         deriving Show


data Expression = E_eq Im Im -- Conditions
                | E_ge Im Im
                | E_le Im Im
                | E_lt Im Im
                | E_ne Im Im
                | E_gt Im Im

                | E_add  Im Im -- Binary ops
                | E_sub  Im Im
                | E_and  Im Im
                | E_or   Im Im
                | E_xor  Im Im
                | E_shl  Im Im
                | E_shr  Im Im
                | E_ushl Im Im
                | E_ushr Im Im
                | E_cmp  Im Im
                | E_cmpg Im Im
                | E_cmpl Im Im
                | E_mul Im Im
                | E_div Im Im
                | E_rem Im Im

                | E_length Im
                | E_cast   Type Im
                | E_instanceOf Im Ref
                | E_newArray Type Im
                | E_new Ref
                | E_newMultiArray Type Im [Im] -- TODO: empty dims?


data InvokeType = I_interface Im
                | I_special   Im
                | I_virtual   Im
                | I_static
                deriving Show

data MethodSignature = MethodSig
                       { methodClass  :: CF.Class
                       , methodName   :: B.ByteString
                       , methodParams :: [Type]
                       , methodResult :: Type         }
                     deriving Show

data Type = T_byte | T_char  | T_int | T_boolean | T_short
          | T_long | T_float | T_double
          | T_object String | T_addr | T_void
          | T_array Type
          deriving Show




instance Show Stmt where
  show (S_breakpoint)    = "breakpoint"

  show (S_assign x a)    = show x ++ " <- " ++ show a

  show (S_enterMonitor i) = "enterMonitor " ++ show i
  show (S_exitMonitor  i) = "exitMonitor " ++ show i

  show (S_goto lbl)      = "goto " ++ show lbl
  show (S_if con lbl)    = "if (" ++ show con ++ ") " ++ show lbl

  show (S_invoke t m ims v) = show v ++ " <- invoke " ++ show t ++ " " ++
                              show m ++ " " ++ show ims

  show (S_lookupSwitch lbl ls) = "lswitch " ++ show lbl ++ " " ++ show ls

  show (S_nop)           = "nop"

  show (S_ret v)         = "return (" ++ show v ++ ")"
  show (S_return i)      = "return (" ++ show i ++ ")"
  show (S_returnVoid)    = "return"

  show (S_tableSwitch i lbl ls) = "tswitch" ++ show i ++ " " ++ show lbl ++ " "
                                  ++ show ls

  show (S_throw i) = "throw " ++ show i



instance Show Im where
  show (IConst c) = show c
  show (ILocal l) = show l

instance Show Variable where
  show (VarRef   ref) = '@' : show ref
  show (VarLocal v  ) = show v

instance Show Value where
  show (VConst c) = show c
  show (VLocal l) = show l
  show (VExpr  e) = show e


instance Show Expression where
  show (E_eq a b) = show a ++ " == " ++ show b
  show (E_ge a b) = show a ++ " >= " ++ show b
  show (E_le a b) = show a ++ " <= " ++ show b
  show (E_ne a b) = show a ++ " /= " ++ show b
  show (E_lt a b) = show a ++ " < " ++ show b
  show (E_gt a b) = show a ++ " > " ++ show b

  show (E_add a b) = show a ++ " + " ++ show b
  show (E_sub a b) = show a ++ " - " ++ show b
  show (E_and a b) = show a ++ " & " ++ show b
  show (E_or  a b) = show a ++ " | " ++ show b
  show (E_xor a b) = show a ++ " ^ " ++ show b
  show (E_shl a b) = show a ++ " shl " ++ show b
  show (E_shr a b) = show a ++ " shr " ++ show b
  show (E_ushl a b) = show a ++ " ushl " ++ show b
  show (E_ushr a b) = show a ++ " ushr " ++ show b
  show (E_cmp a b) = show a ++ " cmp " ++ show b
  show (E_cmpg a b) = show a ++ " cmpg " ++ show b
  show (E_cmpl a b) = show a ++ " cmpl " ++ show b

  show (E_mul a b) = show a ++ " * " ++ show b
  show (E_div a b) = show a ++ " / " ++ show b
  show (E_rem a b) = show a ++ " rem " ++ show b

  show (E_length a) = "len " ++ show a
  show (E_cast t a) = "(" ++ show t ++ ") " ++ show a
  show (E_instanceOf i r) = show i ++ " instanceOf " ++ show r
  show (E_newArray t i) = "new " ++ show t ++ "[" ++ show i ++ "]"
  show (E_new r) = "new " ++ show r
  show (E_newMultiArray t i is) = "new " ++ show t ++ "(" ++ show (i, is) ++ ")"