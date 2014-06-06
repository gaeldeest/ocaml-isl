#!/usr/bin/env runghc

import System.Directory

import Debug.Trace

import Data.List
import Data.Maybe
import Data.Char

import Language.C
import Language.C.System.Preprocess
import Language.C.System.GCC

import Text.PrettyPrint
import Language.C.Pretty

import Language.C.Analysis.AstAnalysis
import Language.C.Analysis.TravMonad
import Language.C.Analysis.SemRep

import Language.C.Data.Ident

import System.IO
import System.IO.Unsafe

import qualified Data.Map as M
import qualified Data.Set as S
import Control.Monad.Writer

data ISLType = INT | UINT | ISL_DIM_TYPE | ISL_SET_PTR | ISL_SPACE_PTR | ISL_MAP_PTR
           | ISL_BASIC_MAP_PTR | ISL_UNION_MAP_PTR | ISL_BASIC_SET_PTR | ISL_CTX_PTR
           | ISL_VAL_PTR | ISL_PW_AFF_PTR | ISL_PRINTER_PTR | ISL_AFF_PTR | ISL_UNION_SET_PTR
           | ISL_MULTI_AFF_PTR | ISL_PW_MULTI_AFF_PTR | VOID_PTR | VOID | ISL_PW_QPOLYNOMIAL_PTR
           | ISL_ID_PTR | ISL_MULTI_VAL_PTR | CHAR_PTR | ISL_QPOLYNOMIAL_PTR | ISL_PW_QPOLYNOMIAL_FOLD_PTR
           | ISL_MAT_PTR | ISL_AST_EXPR_PTR | ISL_LOCAL_SPACE_PTR | ISL_VEC_PTR | ISL_ID_TO_AST_EXPR_PTR
           | ISL_UNION_PW_QPOLYNOMIAL_PTR | ISL_UNION_PW_QPOLYNOMIAL_FOLD_PTR | ISL_PW_AFF_LIST_PTR
           | ISL_CONSTRAINT_PTR | ISL_UNION_PW_MULTI_AFF_PTR | ISL_AST_NODE_PTR | ISL_POINT_PTR
           | ISL_QPOLYNOMIAL_FOLD_PTR | ISL_AST_BUILD_PTR | ISL_BAND_LIST_PTR | ISL_AFF_LIST_PTR
           | ISL_AST_EXPR_LIST_PTR | ISL_AST_NODE_LIST_PTR | ISL_ID_LIST_PTR | ISL_VAL_LIST_PTR
           | FILE_PTR | ISL_BASIC_SET_LIST_PTR | ISL_CONSTRAINT_LIST_PTR | ISL_SET_LIST_PTR
           | ISL_STREAM_PTR | ISL_BAND_PTR | ISL_SCHEDULE_CONSTRAINTS_PTR | ISL_ID_TO_PW_AFF_PTR
           | ISL_MAP_TO_BASIC_SET_PTR | INT_PTR | ISL_AST_PRINT_OPTIONS_PTR | ISL_SET_PTR_PTR
           | SIZE_T | ISL_FOLD | ISL_SCHEDULE_PTR | ISL_ACCESS_INFO_PTR | ISL_TOKEN_PTR
           | ISL_TERM_PTR | UINT32_T | ISL_RESTRICTION_PTR | ISL_HASH_TABLE_PTR | ISL_VERTICES_PTR
           | ULONG | ISL_FLOW_PTR | ISL_VERTEX_PTR | LONG | ISL_ARGS_PTR | ISL_CELL_PTR
           | ISL_UNION_MAP_PTR_PTR | ISL_VAL_PTR_PTR | ISL_OPTIONS_PTR | ISL_OPTIONS_PTR_PTR | CHAR_PTR_PTR
           | ISL_ERROR | DOUBLE | ISL_AST_OP_TYPE | ISL_QPOLYNOMIAL_PTR_PTR |ISL_TOKEN_TYPE
           | ISL_HASH_TABLE_ENTRY_PTR | ISL_AST_NODE_TYPE | ISL_AST_EXPR_TYPE | ISL_MULTI_PW_AFF_PTR
           | ISL_CONSTRAINT_PTR_PTR | ISL_MAT_PTR_PTR | MPZ_T | ISL_LOCAL_SPACE_PTR_PTR
           | ISL_ACCESS_LEVEL_BEFORE | ISL_ACCESS_RESTRICT | BOOL
           deriving (Eq, Show, Ord)
                                                                                                     

data ISLAnnotation = ISL_GIVE | ISL_TAKE | ISL_KEEP | ISL_EXPORT | ISL_CONSTRUCTOR  |ISL_NULL
                   deriving (Eq, Show, Ord)

type Identifier = String
data ISLParam = ISLParam [ISLAnnotation] ISLType Identifier
              deriving (Eq,Show,Ord)

data ISLFunction =  ISLFunction [ISLAnnotation] ISLType Identifier [ISLParam]
              deriving (Eq,Show,Ord)

data Module = Module String (S.Set ISLFunction)

instance Show Module where
  show (Module identifier functions) =
    "Module name: " ++ identifier ++ "\n" ++
    "Module functions: \n" ++
    functionList
    where
      functionList = S.foldr prependFunction "" functions
      prependFunction f str = (maybe "" id (toCamlDeclaration f)) ++ "\n" ++ str

type ParseMonad = WriterT [Module] IO

defines :: [String]
defines =
  ["-D__isl_give=__attribute__((isl_give))",
   "-D__isl_keep=__attribute__((isl_keep))",
   "-D__isl_take=__attribute__((isl_take))",
   "-D__isl_export=__attribute__((isl_export))",
   "-D__isl_null=__attribute__((isl_null))",
   "-D__isl_constructor=__attribute__((isl_constructor)) __attribute__((isl_export))",
   "-D__isl_subclass(super)=__attribute__((isl_subclass(\" #super \"))) __attribute__((isl_export))"
  ]

prefix :: String
prefix = "/usr/local/include/"

includes :: [String]
includes = ["-I"++prefix]

args :: [String]
args = defines ++ includes
  
islDir :: String
islDir = prefix ++ "isl/"

readHeaders :: IO [String]
readHeaders = return  [ "ctx.h"
                      , "space.h"
                      , "map.h"
                      , "union_map.h"
                      , "set.h"
                      , "union_set.h"
                      , "constraint.h"
                      , "aff.h"
                      , "val.h"
                      , "local_space.h"
                      , "id.h"
                      , "ilp.h"
                      ]
-- readHeaders = do
--   all <- getDirectoryContents $ islDir
--   return $ filter (\h -> isHeader h && (not $ isType h) && (not $ elem h blacklist)) all
--   where isHeader = isSuffixOf ".h"
--         isType = isSuffixOf "_type.h"
--         blacklist = [ "hmap.h"
--                     -- , "id_to_ast_expr.h"
--                     -- , "id_to_pw_aff.h"
--                     -- , "map_to_basic_set.h"
--                     ]

withParsedFile :: MonadIO m => (String -> GlobalDecls -> m a) -> String -> m a
withParsedFile f fileName = do
  let gcc = newGCC "/usr/bin/gcc"
  res <- liftIO $ parseCFile gcc  (Just "/tmp") args (islDir ++ fileName)
  case res of
    Left err -> error $ "Error parsing " ++ fileName ++ " : " ++ (show err)
    Right translUnit -> do
      let res = runTrav () (analyseAST translUnit)
      case res of
        Left err -> error $ "Error analyzing AST of " ++ fileName ++ " : " ++ (show err)
        Right (globalDecls, _) -> f fileName globalDecls


camelize :: String -> String
camelize (x:xs) = (toUpper x):(camelize' xs)
  where camelize' (x:xs) | x == '_' = camelize xs
        camelize' (x:xs) = x:(camelize' xs)
        camelize' "" = ""
camelize "" = ""

-- Very inefficient ;)
moduleNameFromHeader :: String -> String
moduleNameFromHeader header = camelize (reverse $ drop 2 $ reverse header)

mlTypes :: M.Map ISLType String
mlTypes = M.fromList [ (VOID, "void")
                     , (INT, "int")
                     , (ISL_CTX_PTR, "Isl.ctx")
                     , (ISL_SET_PTR, "Isl.set")
                     , (ISL_BASIC_SET_PTR, "Isl.basic_set")
                     , (ISL_UNION_SET_PTR, "Isl.union_set")
                     , (ISL_MAP_PTR, "Isl.map")
                     , (ISL_BASIC_MAP_PTR, "Isl.basic_map")
                     , (ISL_UNION_MAP_PTR, "Isl.union_map")
                     , (ISL_AFF_PTR, "Isl.aff")
                     , (ISL_VAL_PTR, "Isl.value")
                     , (ISL_SPACE_PTR, "Isl.space")
                     , (CHAR_PTR, "string")
                     , (BOOL, "Isl.bool")
                     , (ISL_DIM_TYPE, "Isl.dim_type")
                     , (ISL_LOCAL_SPACE_PTR, "Isl.local_space")
                     , (ISL_ID_PTR, "Isl.id")
                     ]

-- lookupType t | trace (show t) False = undefined
lookupType t = M.lookup t mlTypes

toCamlDeclaration :: ISLFunction -> Maybe String
-- toCamlDeclaration f@(ISLFunction annots t name params) | trace name False = undefined
toCamlDeclaration (ISLFunction annots t name params) = do
  mlRetType <- lookupType t
  mlParamTypes <-
    case params of
      [] -> return ["void"]
      _ -> sequence $ map lookupType $ map (\(ISLParam _ t _) -> t) params
  wrappedParams <- fmap concat (sequence $ map wrapParam params)
  retWrap <- gcWrap
  let paramPart = concat (intersperse " @-> " mlParamTypes)
  let cFun = "    let "++ name ++ " = foreign \"" ++ name ++ "\" (" ++ paramPart ++ " @-> returning " ++ mlRetType ++ ") in\n"
  return $ header ++ wrappedParams ++ cFun ++ cFunCall ++ retWrap ++ "    ret\n"
  where header = "let " ++ funName ++ " " ++ paramList ++ " = \n"
        funName = if isPrefixOf "isl_" name then drop 4 name else name
        wrapParam (ISLParam annots t name) =
          if elem ISL_TAKE annots then
            do (copyFun,_) <- lookupMemFunctions t
               return $ "    let " ++ name ++ " = " ++ copyFun ++ " " ++ name ++ " in\n"
          else return ""
        cFunCall = "    let ret = " ++ name ++ " " ++ paramList ++ " in\n"
        gcWrap = if elem ISL_GIVE annots then
                   do (_,freeFun) <- lookupMemFunctions t
                      return $ "    Gc.finalise " ++ freeFun ++ " ret;\n"
                 else return ""
        paramList = concat (intersperse " " paramNames)
        paramNames = map (\(ISLParam _ _ id) -> id) params

toISLAnnotation :: Attr -> Maybe ISLAnnotation
toISLAnnotation attr@(Attr (Ident name _ _) _ _) =
  case name of
    "isl_give" -> Just ISL_GIVE
    "isl_take" -> Just ISL_TAKE
    "isl_keep" -> Just ISL_KEEP
    "isl_export" -> Just ISL_EXPORT
    "isl_constructor" -> Just ISL_CONSTRUCTOR
    "isl_null" -> Just ISL_NULL
    _ -> trace ("Unhandled annotation: " ++ (render $ pretty attr)) Nothing
    

toISLType :: Type -> Maybe ISLType
toISLType t =
  let strType = render $ pretty t in 
  case (render $ pretty t) of
    "isl_ctx *" -> Just ISL_CTX_PTR
    "isl_id_to_ast_expr *" -> Just ISL_ID_TO_AST_EXPR_PTR
    "size_t" -> Just SIZE_T
    "long" -> Just LONG
    "isl_val_list *" -> Just ISL_VAL_LIST_PTR
    "isl_val *" -> Just ISL_VAL_PTR
    "const char *" -> Just CHAR_PTR
    "char *" -> Just CHAR_PTR
    "void" -> Just VOID
    "void *" -> Just VOID_PTR
    "int" -> Just INT
    "unsigned int" -> Just UINT
    "double" -> Just DOUBLE
    "isl_multi_val *" -> Just ISL_MULTI_VAL_PTR
    "isl_ast_build *" -> Just ISL_AST_BUILD_PTR
    "isl_union_set *" -> Just ISL_UNION_SET_PTR
    "struct isl_token *" -> Just ISL_TOKEN_PTR
    "enum isl_token_type" -> Just ISL_TOKEN_TYPE
    "struct isl_obj" -> Nothing
    "struct isl_stream *" -> Just ISL_STREAM_PTR
    "enum isl_fold" -> Just ISL_FOLD
    "struct isl_set *" -> Just ISL_SET_PTR
    "struct isl_basic_set *" -> Just ISL_BASIC_SET_PTR
    "struct isl_mat *" -> Just ISL_MAT_PTR
    "struct isl_vec *" -> Just ISL_VEC_PTR
    "struct isl_map *" -> Just ISL_MAP_PTR
    "struct isl_basic_map *" -> Just ISL_BASIC_MAP_PTR
    "isl_basic_map *" -> Just ISL_BASIC_MAP_PTR
    "struct uint32_t" -> Just UINT32_T
    "uint32_t" -> Just UINT32_T
    "isl_union_map *" -> Just ISL_UNION_MAP_PTR
    "struct isl_constraint *" -> Just ISL_CONSTRAINT_PTR    
    "isl_constraint *" -> Just ISL_CONSTRAINT_PTR
    "isl_basic_set *" -> Just ISL_BASIC_SET_PTR
    "isl_printer *" -> Just ISL_PRINTER_PTR
    "isl_ast_node *" -> Just ISL_AST_NODE_PTR
    "FILE *" -> Just FILE_PTR
    "isl_set *" -> Just ISL_SET_PTR
    "isl_pw_qpolynomial_fold *" -> Just ISL_PW_QPOLYNOMIAL_FOLD_PTR
    "isl_union_pw_qpolynomial_fold *" -> Just ISL_UNION_PW_QPOLYNOMIAL_FOLD_PTR
    "isl_union_pw_qpolynomial *" -> Just ISL_UNION_PW_QPOLYNOMIAL_FOLD_PTR
    "isl_qpolynomial *" -> Just ISL_QPOLYNOMIAL_PTR
    "isl_pw_qpolynomial *" -> Just ISL_PW_QPOLYNOMIAL_PTR
    "isl_band *" -> Just ISL_BAND_PTR
    "isl_band_list *" -> Just ISL_BAND_LIST_PTR
    "struct isl_hash_table *" -> Just ISL_HASH_TABLE_PTR
    "isl_hash_table_entry *" -> Just ISL_HASH_TABLE_ENTRY_PTR
    "isl_constraint_list *" -> Just ISL_CONSTRAINT_LIST_PTR
    "isl_map_to_basic_set *" -> Just ISL_MAP_TO_BASIC_SET_PTR
    "isl_id *" -> Just ISL_ID_PTR
    "isl_local_space *" -> Just ISL_LOCAL_SPACE_PTR
    "enum isl_ast_op_type" -> Just ISL_AST_OP_TYPE
    "isl_ast_print_options *" -> Just ISL_AST_PRINT_OPTIONS_PTR
    "enum isl_ast_node_type" -> Just ISL_AST_NODE_TYPE
    "enum isl_ast_expr_type" -> Just ISL_AST_EXPR_TYPE
    "isl_ast_expr *" -> Just ISL_AST_EXPR_PTR
    "isl_vec *" -> Just ISL_VEC_PTR
    "struct isl_hash_table_entry *" -> Just ISL_HASH_TABLE_ENTRY_PTR
    "isl_id_list *" -> Just ISL_ID_LIST_PTR
    "isl_schedule *" -> Just ISL_SCHEDULE_PTR
    "isl_schedule_constraints *" -> Just ISL_SCHEDULE_CONSTRAINTS_PTR
    "isl_map *" -> Just ISL_MAP_PTR
    "isl_union_pw_multi_aff *" -> Just ISL_UNION_PW_MULTI_AFF_PTR
    "isl_pw_multi_aff *" -> Just ISL_PW_MULTI_AFF_PTR
    "isl_multi_pw_aff *" -> Just ISL_MULTI_PW_AFF_PTR
    "isl_aff *" -> Just ISL_AFF_PTR
    "isl_pw_aff *" -> Just ISL_PW_AFF_PTR
    "isl_multi_aff *" -> Just ISL_MULTI_AFF_PTR
    "isl_id_to_pw_aff *" -> Just ISL_ID_TO_PW_AFF_PTR
    "isl_mat *" -> Just ISL_MAT_PTR
    "struct isl_options *" -> Just ISL_OPTIONS_PTR
    "isl_space *" -> Just ISL_SPACE_PTR
    "isl_access_info *" -> Just ISL_ACCESS_INFO_PTR
    "isl_restriction *" -> Just ISL_RESTRICTION_PTR
    "unsigned long" -> Just ULONG
    "enum isl_error" -> Just ISL_ERROR
    "enum isl_dim_type" -> Just ISL_DIM_TYPE
    "struct isl_ctx *" -> Just ISL_CTX_PTR
    "const void *" -> Just VOID_PTR
    "isl_val * *" -> Just ISL_VAL_PTR_PTR
    "struct isl_val *" -> Just ISL_VAL_PTR
    "struct isl_val_list *" -> Just ISL_VAL_LIST_PTR
    "isl_qpolynomial_fold *" -> Just ISL_QPOLYNOMIAL_FOLD_PTR
    "isl_term *" -> Just ISL_TERM_PTR
    "isl_qpolynomial * *" -> Just ISL_QPOLYNOMIAL_PTR_PTR
    "isl_point *" -> Just ISL_POINT_PTR
    "int *" -> Just INT_PTR
    "struct isl_band *" -> Just ISL_BAND_PTR
    "isl_constraint * *" -> Just ISL_CONSTRAINT_PTR_PTR
    "struct isl_constraint * *" -> Just ISL_CONSTRAINT_PTR_PTR    
    "isl_set * *" -> Just ISL_SET_PTR_PTR
    "struct isl_band_list *" -> Just ISL_BAND_LIST_PTR
    "struct isl_constraint_list *" -> Just ISL_CONSTRAINT_LIST_PTR
    "struct isl_basic_set_list *" -> Just ISL_BASIC_SET_LIST_PTR
    "const struct isl_basic_set_list *" -> Just ISL_BASIC_SET_LIST_PTR
    "struct isl_id *" -> Just ISL_ID_PTR
    "isl_vertex *" -> Just ISL_VERTEX_PTR
    "isl_vertices *" -> Just ISL_VERTICES_PTR
    "isl_cell *" -> Just ISL_CELL_PTR
    "struct isl_args *" -> Just ISL_ARGS_PTR
    "const struct isl_basic_map *" -> Just ISL_BASIC_MAP_PTR
    "const struct isl_map *" -> Just ISL_MAP_PTR
    "isl_pw_aff_list *" -> Just ISL_PW_AFF_LIST_PTR
    "struct isl_id_list *" -> Just ISL_ID_LIST_PTR
    "const struct isl_basic_set *" -> Just ISL_BASIC_SET_PTR
    "isl_ast_expr_list *" -> Just ISL_AST_EXPR_LIST_PTR
    "isl_ast_node_list *" -> Just ISL_AST_NODE_LIST_PTR
    "char * *" -> Just CHAR_PTR_PTR
    "isl_aff_list *" -> Just ISL_AFF_LIST_PTR
    "isl_local_space * *" -> Just ISL_LOCAL_SPACE_PTR_PTR
    "struct isl_mat * *" -> Just ISL_MAT_PTR_PTR
    "mpz_t" -> Just MPZ_T
    "mpz_t const" -> Just MPZ_T
    "isl_access_level_before" -> Just ISL_ACCESS_LEVEL_BEFORE
    "isl_union_map * *" -> Just ISL_UNION_MAP_PTR_PTR
    "isl_flow *" -> Just ISL_FLOW_PTR
    "isl_access_restrict" -> Just ISL_ACCESS_RESTRICT
    _ -> Nothing
    -- _ -> trace ("Unknown type: " ++ strType) Nothing

memoryFunctions :: M.Map ISLType (String, String)
memoryFunctions = M.fromList [ (ISL_SET_PTR, ("set_copy", "set_free"))
                             , (ISL_MAP_PTR, ("map_copy", "map_free"))
                             , (ISL_BASIC_SET_PTR, ("basic_set_copy", "basic_set_free"))
                             , (ISL_BASIC_MAP_PTR, ("basic_map_copy", "basic_map_free"))
                             , (ISL_UNION_SET_PTR, ("union_set_copy", "union_set_free"))
                             , (ISL_UNION_MAP_PTR, ("union_map_copy", "union_map_free"))
                             , (ISL_SPACE_PTR, ("space_copy", "space_free"))
                             , (ISL_AFF_PTR, ("aff_copy", "aff_free"))
                             , (ISL_VAL_PTR, ("val_copy", "val_free"))
                             , (ISL_SPACE_PTR, ("space_copy", "space_free"))
                             , (ISL_LOCAL_SPACE_PTR, ("local_space_copy", "local_space_free"))
                             , (ISL_ID_PTR, ("id_copy", "id_free"))
                             , (CHAR_PTR, ("", "(fun _ -> ())"))
                             ]

-- lookupMemFunctions t | trace ("mem: "++ (show t)) False = undefined
-- lookupMemFunctions t | trace ("res: "++ (show $ M.lookup t memoryFunctions)) False = undefined
lookupMemFunctions t = M.lookup t memoryFunctions

toISLParam :: ParamDecl -> Maybe ISLParam
-- toISLParam p | trace ("Param: " ++ (render $ pretty p)) False = undefined
toISLParam p = do
  let (Ident name _ _) = declIdent p
  let (DeclAttrs _ _ attrs) = declAttrs p
  islType <- toISLType $ declType p
  islAnnotations <- sequence $ map toISLAnnotation attrs
  return $ ISLParam islAnnotations islType name

toISLFun :: (Ident, IdentDecl) -> Maybe ISLFunction
-- toISLFun (Ident name _ _, Declaration (Decl (VarDecl _ declAttrs (FunctionType fType fattrs)) _) ) | trace ("Function: " ++ name) False = undefined
toISLFun (Ident name _ _, Declaration (Decl (VarDecl _ declAttrs (FunctionType fType fattrs)) _) ) =
  case fType of
    FunType t paramDecls _ -> do
      let (DeclAttrs _ _ attrs) = declAttrs
      islAnnots <- sequence $ map toISLAnnotation attrs
      -- let islAnnots = []
      retType <- toISLType t
      islParams <- sequence $ map toISLParam paramDecls
      return $ ISLFunction islAnnots retType name islParams
    -- _ -> trace ("Unhandled function: "++name) Nothing
    _ -> Nothing
toISLFun _ = Nothing

sanitizeFun :: ISLFunction -> ISLFunction
sanitizeFun (ISLFunction annotations t name params) =
  ISLFunction annotations newType name newParams
  where newType =
          if t == INT &&
             ( any (flip isInfixOf name) [ "_is_"
                                         , "_has_"
                                         , "_can_"
                                         ] ||
               any (flip isSuffixOf name) [ "_compatible"
                                          , "_match"
                                          , "_lt"
                                          , "_le"
                                          , "_gt"
                                          , "_ge"
                                          , "_eq"
                                          , "_ne"
                                          ]
               
             ) then BOOL
                  else t
        newParams = map sanitizeParam params
        sanitizeParam param@(ISLParam annotatations t name) =
          case M.lookup name paramReplacements of
            Just newParamName -> ISLParam annotations t newParamName
            Nothing -> param
        paramReplacements = M.fromList
                            [ ("mod", "modulo")
                            , ("type", "typ")
                            , ("val", "value")
                            ]

mustKeepFun :: ISLFunction -> Bool
mustKeepFun (ISLFunction annots _ name _) =
  not ((elem ISL_NULL annots) || (isSuffixOf "_free" name) || (isSuffixOf "_copy" name))
                            
collectModules :: [String] -> ParseMonad ()
collectModules headers = mapM_ (withParsedFile addModule) headers
  where addModule header decls = tell [Module moduleName $ S.fromList islFuns]
          where moduleName = moduleNameFromHeader header
                filterFile (Ident _ _ ni, _) =
                  case (fileOfNode ni) of
                    Nothing -> False
                    Just file -> (file == islDir ++ header) || file == (islDir ++ "hmap.h")
                islFuns = map sanitizeFun $ filter mustKeepFun $ catMaybes $ map toISLFun $ filter filterFile $ M.toList $ gObjs decls

writeFuns :: [ISLFunction] -> Handle -> IO ()
writeFuns functions h = mapM_ writeFun functions
  where
    -- writeFun (ISLFunction _ _ name _) | trace name False = undefined
    writeFun f = case toCamlDeclaration f of
          Just str -> hPutStr h (str ++ "\n")
          Nothing -> return ()

writeModule :: Module -> IO ()
writeModule (Module identifier functions) =
  withFile moduleFileName WriteMode writeModule
  where writeModule h = do
          hPutStr h "open Ctypes\n"
          hPutStr h "open Foreign\n"          
          hPutStr h "open IslMemory\n\n"
          writeFuns funs h
        funs = S.toList functions
        moduleFileName = case identifier of
          (x:xs) -> "src/gen/in_" ++ identifier ++ ".ml"
          _ -> error "Empty module identifier !"
        
main :: IO ()
main = do
  headers <- readHeaders
  (_,modules) <- runWriterT $ collectModules headers
  mapM_ writeModule modules
