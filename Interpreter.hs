{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Interpreter ( evalTopLevel ) where

import AST
import Control.Monad.Except
import Data.IORef
import Types
import Utils

evalTopLevel :: TopLevel -> KLContext Env KLValue
evalTopLevel (SE se) = reduceSExpr [] se >>= eval []
evalTopLevel (Defun name args body) = evalDefun name args body

evalDefun :: Symbol -> ParamList -> SExpr -> KLContext Env KLValue
evalDefun name args body = do
  body' <- reduceSExpr args body
  let f = topLevelContext (length args) body'
  insertFunction name f                 
  return (Atom (UnboundSym name))

topLevelContext :: Int -> RSExpr -> ApplContext
topLevelContext 0 e = PL (eval [] e)
topLevelContext n e = Func (buildContext n [])
    where buildContext 1 vals = Context (\x -> eval ((n-1,x):vals) e)
          buildContext m vals = PartialApp fn
              where fn x = buildContext (m-1) ((n-m,x):vals)

eval :: Bindings -> RSExpr -> KLContext Env KLValue
eval vals (RDeBruijn db)    = lookupVal db vals
eval vals (RFreeze e)       = evalFreeze vals e
eval vals (RTrapError e tr) = evalTrapError vals e tr
eval vals (RLambda i e)     = evalLambda vals i e
eval vals (RIf c t f)       = evalIf vals c t f
eval vals (RApplDir f as)   = evalApplDir vals f as
eval vals (RApplForm a as)  = evalApplForm vals a as
eval vals (RLit a)          = return (checkForBooleans a)
eval vals REmptyList        = return (List [])

evalTrapError :: Bindings -> RSExpr -> RSExpr -> KLContext Env KLValue
evalTrapError vals e tr = eval vals e `catchError` handleError
    where handleError e =
              eval vals tr >>= \case
                   ApplC (Func f) -> applyList (Func f) [Excep e]
                   _ -> throwError "exception handler must be a function"
                   
evalFreeze :: Bindings -> RSExpr -> KLContext Env KLValue
evalFreeze vals e = return (ApplC (PL (eval vals e)))

evalLambda :: Monad m => Bindings -> DeBruijn -> RSExpr -> m KLValue
evalLambda vals i = return . ApplC . Func . evalLambda' vals i
    where evalLambda' vals i e
              | RLambda i' e' <- e = PartialApp (contLambda i' e')
              | otherwise = Context termLambda
              where termLambda x = eval (addVal i vals x) e
                    contLambda i' e' x = evalLambda' (addVal i vals x) i' e'

evalApplDir' :: Bindings -> ApplContext -> [RSExpr] -> KLContext Env KLValue
evalApplDir' vals ac args = mapM' (eval vals) args >>= applyList ac

evalApplDir :: Bindings -> IORef ApplContext -> [RSExpr] -> KLContext Env KLValue
evalApplDir vals ref args = fromIORef ref >>= \ac -> evalApplDir' vals ac args

evalApplForm :: Bindings -> RSExpr -> [RSExpr] -> KLContext Env KLValue
evalApplForm vals (RLit (UnboundSym name)) args =
    functionRef name >>= \ac -> evalApplDir vals ac args    
evalApplForm vals form args =
    eval vals form >>= \case
         ApplC ac -> evalApplDir' vals ac args
         Atom (UnboundSym n) -> evalApplForm vals (RLit (UnboundSym n)) args
         v -> exceptionV "(form . args): form evaluates to" v

evalIf :: Bindings -> RSExpr -> RSExpr -> RSExpr -> KLContext Env KLValue
evalIf vals c t f =
    eval vals c >>= \case
         Atom (B True)  -> eval vals t
         Atom (B False) -> eval vals f
         _              -> throwError "(if c t f): c must evaluate to boolean"

applyList :: ApplContext -> [KLValue] -> KLContext Env KLValue
applyList (Malformed e) _ = throwError e
applyList (PL c) [] = c
applyList f      [] = return (ApplC f)
applyList (Func f) (v:vs) = applyList (apply f v) vs
applyList _ _ = throwError "too many arguments"
