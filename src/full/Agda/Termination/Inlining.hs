{-# LANGUAGE CPP #-}

#if __GLASGOW_HASKELL__ >= 710
{-# LANGUAGE FlexibleContexts #-}
#endif

-- Author:  Ulf Norell
-- Created: 2013-11-09

{-|
  This module defines an inlining transformation on clauses that's run before
  termination checking. The purpose is to improve termination checking of with
  clauses (issue 59). The transformation inlines generated with-functions
  expanding the clauses of the parent function in such a way that termination
  checking the expanded clauses guarantees termination of the original function,
  while allowing more terminating functions to be accepted. It does in no way
  pretend to preserve the semantics of the original function.

  Roughly, the source program

> f ps with as
> {f ps₁i qsi = bi}

  is represented internally as

> f ps = f-aux xs as      where xs   = vars(ps)
> {f-aux ps₂i qsi = bi}   where ps₁i = ps[ps₂i/xs]

  The inlining transformation turns this into

> {f ps = aj} for aj ∈ as
> {f ps₁i qsi = bi}

  The first set of clauses, called 'withExprClauses', ensure that we
  don't forget any recursive calls in @as@.
  The second set of clauses, henceforth called 'inlinedClauses',
  are the surface-level clauses the user sees (and probably reasons about).

  The reason this works is that there is a single call site for each
  with-function.

  Note that the lhss of the inlined clauses are not type-correct,
  neither with the type of @f@ (since there are additional patterns @qsi@)
  nor with the type of @f-aux@ (since there are the surface-level patterns
  @ps₁i@ instead of the actual patterns @ps₂i@).
 -}
module Agda.Termination.Inlining
  ( inlineWithClauses
  , isWithFunction
  , expandWithFunctionCall ) where

import Control.Applicative
import Control.Monad.State

import Data.Traversable (traverse)
import Data.List as List

import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.Syntax.Internal.Pattern
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.DisplayForm
import Agda.TypeChecking.Telescope

import Agda.Utils.List (downFrom)
import Agda.Utils.Maybe
import Agda.Utils.Monad
import Agda.Utils.Permutation
import Agda.Utils.Size

import Agda.Utils.Impossible
#include "undefined.h"

inlineWithClauses :: QName -> Clause -> TCM [Clause]
inlineWithClauses f cl = inTopContext $ do
  -- Clauses are relative to the empty context, so we operate @inTopContext@.
  let noInline = return [cl]
  -- Get the clause body as-is (unraised).
  -- The de Bruijn indices are then relative to the @clauseTel cl@.
  body <- traverse instantiate $ getBodyUnraised cl
  case body of
    Just (Def wf els) ->
      caseMaybeM (isWithFunction wf) noInline $ \ f' ->
      if f /= f' then noInline else do
        -- The clause body is a with-function call @wf args@.
        -- @f@ is the function the with-function belongs to.
        let args = fromMaybe __IMPOSSIBLE__ . allApplyElims $ els

        reportSDoc "term.with.inline" 70 $ sep
          [ text "Found with (raw):", nest 2 $ text $ show cl ]
        reportSDoc "term.with.inline" 20 $ sep
          [ text "Found with:", nest 2 $ prettyTCM $ QNamed f cl ]

        t   <- defType <$> getConstInfo wf
        cs1 <- withExprClauses cl t args

        reportSDoc "term.with.inline" 70 $ vcat $
          text "withExprClauses (raw)" : map (nest 2 . text . show) cs1
        reportSDoc "term.with.inline" 20 $ vcat $
          text "withExprClauses" : map (nest 2 . prettyTCM . QNamed f) cs1

        cs2 <- inlinedClauses f cl t wf

        reportSDoc "term.with.inline" 70 $ vcat $
          text "inlinedClauses (raw)" : map (nest 2 . text . show) cs2
        reportSDoc "term.with.inline" 20 $ vcat $
          text "inlinedClauses" : map (nest 2 . prettyTCM . QNamed f) cs2

        return $ cs1 ++ cs2
    _ -> noInline

-- | @withExprClauses cl t as@ generates a clause containing a fake
--   call to with-expression @a@ for each @a@ in @as@ that is not
--   a variable (and thus cannot contain a recursive call).
--
--   Andreas, 2013-11-11: I guess "not a variable" could be generalized
--   to "not containing a call to a mutually defined function".
--
--   Note that the @as@ stem from the *unraised* clause body of @cl@
--   and thus can be simply 'fmap'ped back there (under all the 'Bind'
--   abstractions).
--
--   Precondition: we are 'inTopContext'.
withExprClauses :: Clause -> Type -> Args -> TCM [Clause]
withExprClauses cl t args = {- addContext (clauseTel cl) $ -} loop t args where
  -- Note: for the following code, it does not matter which context we are in.
  -- Restore the @addContext (clauseTel cl)@ if that should become necessary
  -- (like when debug printing @args@ etc).
  loop t []     = return []
  loop t (a:as) =
    case unArg a of
      Var i [] -> rest  -- TODO: smarter criterion when to skip withExprClause
      v        ->
        (cl { clauseBody = v <$ clauseBody cl
            , clauseType = Just $ defaultArg dom
            } :) <$> rest
    where
      rest = loop (piApply t [a]) as
      dom  = case unEl t of   -- The type is the generated with-function type so we know it
        Pi a _  -> unDom a    -- doesn't contain anything funny
        _       -> __IMPOSSIBLE__

-- | @inlinedClauses f cl t wf@ inlines the clauses of with-function @wf@
--   of type @t@ into the clause @cl@.  The original function name is @f@.
--
--   Precondition: we are 'inTopContext'.
inlinedClauses :: QName -> Clause -> Type -> QName -> TCM [Clause]
inlinedClauses f cl t wf = do
  -- @wf@ might define a with-function itself, so we first construct
  -- the with-inlined clauses @wcs@ of @wf@ recursively.
  wcs <- concat <$> (mapM (inlineWithClauses wf) =<< defClauses <$> getConstInfo wf)
  reportSDoc "term.with.inline" 30 $ vcat $ text "With-clauses to inline" :
                                       map (nest 2 . prettyTCM . QNamed wf) wcs
  mapM (inline f cl t wf) wcs

-- | The actual work horse.
--   @inline f pcl t wf wcl@ inlines with-clause @wcl@ of with-function @wf@
--   (of type @t@) into parent clause @pcl@ (original function being @f@).
inline :: QName -> Clause -> Type -> QName -> Clause -> TCM Clause
inline f pcl t wf wcl = inTopContext $ addContext (clauseTel wcl) $ do
  -- The tricky part here is to get the variables to line up properly. The
  -- order of the arguments to the with-function is not the same as the order
  -- of the arguments to the parent function. Fortunately we have already
  -- figured out how to turn an application of the with-function into an
  -- application of the parent function in the display form.
  reportSDoc "term.with.inline" 70 $ text "inlining (raw) =" <+> text (show wcl)
  let vs = clauseArgs wcl
  Just disp <- displayForm wf vs
  reportSDoc "term.with.inline" 70 $ text "display form (raw) =" <+> text (show disp)
  reportSDoc "term.with.inline" 40 $ text "display form =" <+> prettyTCM disp
  (pats, perm) <- dispToPats disp

  -- Now we need to sort out the right hand side. We have
  --    Γ  - clause telescope (same for with-clause and inlined clause)
  --    Δw - variables bound in the patterns of the with clause
  --    Δi - variables bound in the patterns of the inlined clause
  --    Δw ⊢ clauseBody wcl
  -- and we want
  --    Δi ⊢ body
  -- We can use the clause permutations to get there (renaming is bugged and
  -- shouldn't need the reverseP):
  --    applySubst (renaming $ reverseP $ clausePerm wcl) : Term Δw -> Term Γ
  --    applySubst (renamingR perm)                       : Term Γ -> Term Δi
  -- Finally we need to add the right number of Bind's to the body.
  let body = rebindBody (permRange perm) $
             applySubst (renamingR perm) .
             applySubst (renaming $ reverseP $ clausePerm wcl)
              <$> clauseBody wcl
  return wcl { namedClausePats = numberPatVars perm pats
             , clauseBody      = body
             , clauseType      = Nothing -- TODO: renaming of original clause type
             }
  where
    numVars  = size (clauseTel wcl)

    rebindBody n b = bind n $ maybe NoBody Body $ getBodyUnraised b
      where
        bind 0 = id
        bind n = Bind . Abs (stringToArgName $ "h" ++ show n') . bind n'
          where n' = n - 1

    dispToPats :: DisplayTerm -> TCM ([NamedArg Pattern], Permutation)
    dispToPats (DWithApp (DDef _ es) ws zs) = do
      let es' = es ++ map Apply (map defaultArg ws ++ map (fmap DTerm) zs)
      (ps, (j, ren)) <- (`runStateT` (0, [])) $ mapM (traverse dtermToPat) es'
      let perm = Perm j (map snd $ List.sort ren)
      return (map ePatToPat ps, perm)
    dispToPats t = __IMPOSSIBLE__

    bindVar i = do
      (j, is)  <- get
      let i' = numVars - i - 1
      case lookup i' is of
        Nothing -> True  <$ put (j + 1, (i', j) : is)
        Just{}  -> False <$ put (j + 1, is)

    skip = modify $ \(j, is) -> (j + 1, is)

    ePatToPat :: Elim' Pattern -> NamedArg Pattern
    ePatToPat (Apply p) = fmap unnamed p
    ePatToPat (Proj  d) = defaultNamedArg $ ProjP d

    dtermToPat :: DisplayTerm -> StateT (Int, [(Int, Int)]) TCM Pattern
    dtermToPat v =
      case v of
        DWithApp{}       -> __IMPOSSIBLE__   -- I believe
        DCon c vs        -> ConP c noConPatternInfo . map (fmap unnamed)
                              <$> mapM (traverse dtermToPat) vs
        DDef d es        -> do
          ifM (return (null es) `and2M` do isJust <$> lift (isProjection d))
            {-then-} (return $ ProjP d)
            {-else-} (DotP (dtermToTerm v) <$ skip)
        DDot v           -> DotP v <$ skip
        DTerm (Var i []) ->
          ifM (bindVar i) (VarP . nameToPatVarName <$> lift (nameOfBV i))
                          (pure $ DotP (Var i []))
        DTerm (Con c vs) -> ConP c noConPatternInfo . map (fmap unnamed) <$>
                              mapM (traverse (dtermToPat . DTerm)) vs
        DTerm v          -> DotP v <$ skip

isWithFunction :: MonadTCM tcm => QName -> tcm (Maybe QName)
isWithFunction x = liftTCM $ do
  def <- getConstInfo x
  return $ case theDef def of
    Function{ funWith = w } -> w
    _                       -> Nothing

expandWithFunctionCall :: QName -> Elims -> TCM Term
expandWithFunctionCall f es = do
  as <- displayFormArities f
  case as of
    [a] | length vs >= a -> do
      Just disp <- displayForm f vs
      return $ dtermToTerm disp `applyE` es'
    -- We might get an underapplied with function application (issue1598), in
    -- which case we have to eta expand. The resulting term is only used for
    -- termination checking, so we don't have to worry about getting hiding
    -- information right.
    [a] | null es' -> do
      let pad = a - length vs
          vs' = raise pad vs ++ map (defaultArg . var) (downFrom pad)
      Just disp <- displayForm f vs'
      return $ foldr (\_ -> Lam defaultArgInfo . Abs "") (dtermToTerm disp) (replicate pad ())
    _ -> __IMPOSSIBLE__
  where
    (vs, es') = splitApplyElims es
