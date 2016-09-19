-----------------------------------------------------------------------------
-- |
-- Module      :  Main
-- Author      :  Troels Henriksen <athas@sigkill.dk>
-- License     :  MIT-style (see LICENSE)
--
-- Stability   :  stable
-- Portability :  unportable
--
-- gsmenu, a generic grid-based menu.
--
-----------------------------------------------------------------------------

module Main (main) where

import Control.Applicative
import Control.Exception (catch, SomeException(..))
import Control.Monad
import Control.Monad.Trans

import Data.Maybe
import Data.List
import Data.Word (Word8)

import Graphics.X11.Xlib hiding (refreshKeyboardMapping)
import Graphics.X11.Xinerama

import System.Console.GetFlag
import System.Environment
import System.Exit
import System.IO

import Text.Parsec hiding ((<|>), many, optional)
import Text.Parsec.String

import Text.Printf

import GSMenu.Config
import GSMenu.Pick
import GSMenu.Util

data AppConfig a = AppConfig {
      cfg_complex   :: Bool
    , cfg_display   :: String
    , cfg_enumerate :: Bool
    , cfg_gpconfig  :: GPConfig a
  }

defaultConfig :: AppConfig a
defaultConfig = AppConfig {
                  cfg_complex   = False
                , cfg_display   = ""
                , cfg_enumerate = False
                , cfg_gpconfig  = defaultGPConfig
                }

main :: IO ()
main = do
  opts  <- getOpt RequireOrder options <$> getArgs
  dstr  <- getEnv "DISPLAY" `catch` (\(SomeException _) -> return "")
  let cfg = defaultConfig { cfg_display = dstr }
  case opts of
    (opts', [], []) -> runWithCfg =<< foldl (>>=) (return cfg) opts'
    (_, nonopts, errs) -> do 
              mapM_ (hPutStrLn stderr . ("Junk argument: " ++)) nonopts
              usage <- usageStr
              hPutStr stderr $ concat errs ++ usage
              exitFailure

runWithCfg :: AppConfig [String] -> IO ()
runWithCfg cfg = do 
  dpy   <- setupDisplay $ cfg_display cfg
  let screen = defaultScreenOfDisplay dpy
  elems <- reader stdin valuer
  rect  <- findRectangle dpy (rootWindowOfScreen screen)
  sel   <- gpick dpy screen rect (cfg_gpconfig cfg) elems
  case sel of
    Left reason      -> err reason >> exitWith (ExitFailure 1)
    Right Nothing    -> exitWith $ ExitFailure 2
    Right (Just els) -> printer els >> exitSuccess
    where reader
           | cfg_complex cfg = readElementsC "stdin"
           | otherwise       = readElements
          printer (x:xs:rest) = putStrLn x *> printer (xs:rest)
          printer [x]         = putStr x
          printer _           = return ()
          valuer
           | cfg_enumerate cfg = const $ (:[]) . show
           | otherwise         = \s _ -> [s]

setupDisplay :: String -> IO Display
setupDisplay dstr =
  openDisplay dstr `catch` \(SomeException _) ->
    error $ "Cannot open display \"" ++ dstr ++ "\"."

findRectangle :: Display -> Window -> IO Rectangle
findRectangle dpy rootw = do
  (_, _, _, x, y, _, _, _) <- queryPointer dpy rootw
  let hasPointer rect = fi x >= rect_x rect &&
                        fi (rect_width rect) + rect_x rect > fi x &&
                        fi y >= rect_y rect &&
                        fi (rect_height rect) + rect_y rect > fi y
  fromJust <$> find hasPointer <$> getScreenInfo dpy

readElements :: MonadIO m => Handle 
             -> (String -> Integer -> [String])
             -> m [Element [String]]
readElements h f = do
  str   <- io $ hGetContents h
  return $ zipWith mk (lines str) [0..]
      where mk line num = Element
                          { el_colors = ("black", "white")
                          , el_data   = f line num
                          , el_disp   = (line, [])
                          , el_tags   = [] }
                          
readElementsC :: MonadIO m => SourceName
              -> Handle
              -> (String -> Integer -> [String])
              -> m [Element [String]]
readElementsC sn h f = do
  str   <- io $ hGetContents h
  case parseElements sn str of
    Left  e   -> error $ show e
    Right els -> return $ zipWith mk els [0..]
        where mk elm num =
                  elm { el_data = fromMaybe 
                                  (f (fst $ el_disp elm) num) 
                                  (el_data elm)
                      }

type GSMenuOption a = OptDescr (AppConfig a -> IO (AppConfig a))

inGPConfig :: (String -> GPConfig a -> GPConfig a)
            -> String -> AppConfig a -> IO (AppConfig a)
inGPConfig f arg cfg = return $ cfg { cfg_gpconfig = f arg (cfg_gpconfig cfg) }

tryRead :: Read a => (String -> String) -> String -> a
tryRead ef s = case reads s of
                [(x, "")] -> x
                _         -> error $ ef s

readInt :: (Integral a, Read a) => String -> a
readInt = tryRead $ (++ " is not an integer.") . quote

readFloat :: (Fractional a, Read a) => String -> a
readFloat = tryRead $ (++ " is not a decimal fraction.") . quote

usageStr :: IO String
usageStr = do
  prog <- getProgName
  let header = "Help for " ++ prog ++ " " ++ versionStr
  return $ usageInfo header options

versionStr :: String
versionStr = "2.2"

options :: [GSMenuOption a]
options = [ Option "c"
            (NoArg (\cfg -> return $ cfg { cfg_complex = True }))
            "Use complex input format."
          , Option "e"
            (NoArg (\cfg -> return $ cfg { cfg_enumerate = True }))
            "Print the result as the (zero-indexed) element number."
          , Option "cellheight"
            (ReqArg (inGPConfig $ \arg gpc ->
                      gpc { gp_cellheight = readInt arg }) "height")
            "The height of each element cell"
          , Option "cellwidth"
            (ReqArg (inGPConfig $ \arg gpc ->
                      gpc { gp_cellwidth = readInt arg }) "width")
            "The width of each element cell"
          , Option "cellpadding"
            (ReqArg (inGPConfig $ \arg gpc ->
                      gpc { gp_cellpadding = readInt arg }) "padding")
            "The inner padding of each element cell."
          , Option "font"
            (ReqArg (inGPConfig $ \arg gpc ->
                      gpc { gp_font = arg }) "font")
            "The font used for printing names of elements."
          , Option "subfont"
            (ReqArg (inGPConfig $ \arg gpc ->
                      gpc { gp_subfont = arg}) "font")
            "The font used for printing extra lines in elements."
          , Option "inputfont"
            (ReqArg (inGPConfig $ \arg gpc ->
                      gpc { gp_inputfont = arg}) "font")
            "The font used for the input field."
          , Option "x"
            (ReqArg (inGPConfig $ \arg gpc ->
                      gpc { gp_originFractX = readFloat arg }) "float")
            "The horizontal center of the grid, range [0,1]."
          , Option "y"
            (ReqArg (inGPConfig $ \arg gpc ->
                      gpc { gp_originFractY = readFloat arg }) "float")
            "The vertical center of the grid, range [0,1]"
          ]
               
parseElements :: SourceName -> String -> Either ParseError [Element (Maybe [String])]
parseElements = parse $ many element <* eof

blankElem :: Element (Maybe a)
blankElem = Element {
              el_colors = ("black", "white")
            , el_data   = Nothing
            , el_disp   = error "Element without display."
            , el_tags   = []
            }

tagColors :: [String] -> (String, String)
tagColors ts =
  let seed x = toInteger (sum $ map ((*x).fromEnum) s) :: Integer
      (r,g,b) = hsv2rgb (seed 83 `mod` 360,
                         fi (seed 191 `mod` 1000)/2500+0.4,
                         fi  (seed 121 `mod` 1000)/2500+0.4)
  in ("white", '#' : concatMap (twodigitHex.(round :: Double -> Word8).(*256)) [r, g, b] )
    where s = show ts

twodigitHex :: Word8 -> String
twodigitHex = printf "%02x"

element :: GenParser Char u (Element (Maybe [String]))
element = do kvs <- kvPair `sepBy1` realSpaces <* spaces
             let (fg, bg) = tagColors $ tags kvs
             foldM procKv blankElem { el_colors = (fg, bg) } kvs
    where tags (("tags",ts):ls) = ts ++ tags ls
          tags ((_,_):ls)       = tags ls
          tags []               = []
          procKv elm ("name", val : more) =
            return elm { el_disp = (val, more) }
          procKv _   ("name", _) = badval "name"
          procKv elm ("fg", [val]) =
            return elm {
              el_colors = (val, snd $ el_colors elm) }
          procKv _   ("fg", _) = badval "fg"
          procKv elm ("bg", [val]) =
            return elm {
              el_colors = (fst $ el_colors elm, val) }
          procKv _   ("bg", _) = badval "bg"
          procKv elm ("tags",val) =
            return elm { el_tags = el_tags elm ++ filter (/="") val }
          procKv elm ("value",val) =
            return elm { el_data = Just val }
          procKv _ (k, _) = nokey k
          badval = parserFail . ("Bad value for field " ++) . quote
          nokey  = parserFail . ("Unknown key " ++) . quote

kvPair :: GenParser Char u (String, [String])
kvPair =
  pure (,) <*> (many1 alphaNum <* realSpaces <* char '=' <* realSpaces)
           <*> many1 (value <* realSpaces)

value :: GenParser Char u String
value = char '"' *> escapedStr

escapedStr :: GenParser Char u String
escapedStr = do
  s <- many $ noneOf "\"\n"
  (    try (string "\"\"" *> pure ((s++"\"")++) <*> escapedStr)
   <|> try (string "\"" *> return s))

realSpaces :: GenParser Char u String
realSpaces = many $ char ' '
