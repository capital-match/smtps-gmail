{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS -Wall              #-}

-- |
-- Module      : Network.Mail.Client.Gmail
-- Copyright   : Copyright (c) 2014, Enzo Haussecker. All rights reserved.
-- License     : BSD3
-- Maintainer  : Enzo Haussecker <ehaussecker@gmail.com>
-- Stability   : Experimental
-- Portability : Unknown
--
-- A simple SMTP Client for sending Gmail.
module Network.Mail.Client.Gmail (sendGmail) where

import Control.Monad (foldM_, forM)
import Control.Exception (bracket)
import Crypto.Random.AESCtr (makeSystem)
import Data.ByteString.Char8 (lines, unpack)
import Data.ByteString.Base64.Lazy (encode)
import Data.ByteString.Lazy.Char8 (ByteString, readFile)
import Data.ByteString.Lazy.Search (replace)
import Data.Char (isDigit, isSpace)
import Data.Default (def)
import Data.Monoid ((<>))
import Data.Text as Strict (Text, pack)
import Data.Text.Lazy as Lazy (Text, fromChunks)
import Data.Text.Lazy.Encoding (encodeUtf8)
import Network (PortID(PortNumber), connectTo)
import Network.Mail.Mime hiding (renderMail)
import Network.TLS
import Network.TLS.Extra
import Prelude hiding (any, lines, readFile)
import System.FilePath (takeExtension, takeFileName)
import System.IO hiding (readFile)

-- | Send an email from your Gmail account using the
--   simple message transfer protocol with transport
--   layer security. If you have 2-step verification
--   enabled on your account, then you will need to
--   retrieve an application specific password before
--   using this function. Below is an example using
--   ghci, where Alice sends an Excel spreadsheet to
--   Bob.
--
-- > >>> :set -XOverloadedStrings
-- > >>> :module Network.Mail.Mime Network.Mail.Client.Gmail
-- > >>> sendGmail "alice" "password" (Address (Just "Alice") "alice@gmail.com") [Address (Just "Bob") "bob@example.com"] [] [] "Excel Spreadsheet" "Hi Bob,\n\nThe Excel spreadsheet is attached.\n\nRegards,\n\nAlice" ["Spreadsheet.xls"]
--
sendGmail
   :: Lazy.Text   -- ^ username
   -> Lazy.Text   -- ^ password
   -> Address     -- ^ from
   -> [Address]   -- ^ to
   -> [Address]   -- ^ cc
   -> [Address]   -- ^ bcc
   -> Strict.Text -- ^ subject
   -> Lazy.Text   -- ^ body
   -> [FilePath]  -- ^ attachments
   -> IO ()
sendGmail user pass from to cc bcc subject body attach = 
   bracket (connectTo "smtp.gmail.com" $ PortNumber 587) hClose $ \ hdl -> do
      sys   <- makeSystem
      ctx   <- contextNew hdl params sys
      _MAIL <- renderMail from to cc bcc subject body attach
      hSetBuffering hdl LineBuffering
      sendSMTP  hdl "EHLO"       >> recvSMTP  hdl "220"
                                 >> recvSMTP  hdl "250"
      sendSMTP  hdl "STARTTLS"   >> recvSMTP  hdl "220"
      handshake ctx
      sendSMTPS ctx "EHLO"       >> recvSMTPS ctx "250"
      sendSMTPS ctx "AUTH LOGIN" >> recvSMTPS ctx "334"
      sendSMTPS ctx _USERNAME    >> recvSMTPS ctx "334"
      sendSMTPS ctx _PASSWORD    >> recvSMTPS ctx "235"
      sendSMTPS ctx _FROM        >> recvSMTPS ctx "250"
      sendSMTPS ctx _TO          >> recvSMTPS ctx "250"
      sendSMTPS ctx "DATA"       >> recvSMTPS ctx "354"
      sendSMTPS ctx _MAIL        >> recvSMTPS ctx "250"
      sendSMTPS ctx "QUIT"       >> recvSMTPS ctx "221"
      bye ctx
      contextClose ctx
      where _USERNAME  = encode $ encodeUtf8 user
            _PASSWORD  = encode $ encodeUtf8 pass
            _FROM      = "MAIL FROM: " <> angleBracket [from]
            _TO        = "RCPT TO: "   <> angleBracket (to ++ cc ++ bcc)

-- | Display the first email address in the given list using angle bracket formatting.
angleBracket :: [Address] -> ByteString
angleBracket = \ case [] -> ""; (Address _ email:_) -> "<" <> encodeUtf8 (fromChunks [email]) <> ">"

-- | Render an email using the RFC 2822 message format.
renderMail
   :: Address     -- ^ from
   -> [Address]   -- ^ to
   -> [Address]   -- ^ cc
   -> [Address]   -- ^ bcc
   -> Strict.Text -- ^ subject
   -> Lazy.Text   -- ^ body
   -> [FilePath]  -- ^ attachments
   -> IO ByteString
renderMail from to cc bcc subject body attach = do
   parts <- forM attach $ \ path -> do
      content <- readFile path
      let mime = getMime $ takeExtension path
          file = Just . pack $ takeFileName path
      return $! [Part mime Base64 file [] content]
   let plain = [Part "text/plain; charset=utf-8" QuotedPrintableText Nothing [] $ encodeUtf8 body]
   mail <- renderMail' . Mail from to cc bcc headers $ plain : parts
   return $! replace "\n." ("\n.."::ByteString) mail <> "\r\n.\r\n"
   where headers = [("Subject",subject)]

-- | Send an unencrypted message using the simple message transfer protocol.
sendSMTP :: Handle -> String -> IO ()
sendSMTP = hPutStrLn

-- | Receive an unencrypted message using the simple message transfer protocol.
recvSMTP :: Handle -> String -> IO ()
recvSMTP hdl code = go [] >> return ()
   where go accum = hGetLine hdl >>= \ reply -> match code reply go accum

-- | Send an encrypted message using the simple message transfer protocol.
sendSMTPS :: Context -> ByteString -> IO ()
sendSMTPS ctx msg = sendData ctx $ msg <> "\r\n"

-- | Receive an encrypted message using the simple message transfer protocol.
recvSMTPS :: Context -> String -> IO ()
recvSMTPS ctx code = recvData ctx >>= foldM_ step [] . lines
   where step accum reply = match code (unpack reply) return accum

-- | A convenient type synonym.
type Continuation = [String] -> IO [String]

-- | Match reply codes and perform continuation, termination, and failure case analysis.
match
   :: String       -- ^ expected reply code
   -> String       -- ^ actual reply code
   -> Continuation -- ^ continuation
   -> [String]     -- ^ accumulator
   -> IO [String]
match code reply go accum =
   if not (null suffix) && head suffix == '-'
   then go $ drop 1 suffix:accum
   else if prefix == code && "" /= code
        then return []
        else mismatch code prefix $ suffix:accum
        where (prefix, suffix) = break (not . isDigit) reply

-- | Raise an exception for mismatched reply codes.
mismatch
   :: String   -- ^ expected reply code
   -> String   -- ^ actual reply code
   -> [String] -- ^ messages
   -> IO [String]
mismatch code other replies = fail $
   if null code
   then "mismatch: missing expected reply code."
   else "mismatch: expected reply code " ++ code ++
    (if null other
     then ", but no reply code was received"
     else ", but received reply code " ++ other) ++
     case filter (not . null) $ map strip replies of
       []     -> "."
       (r:rs) -> ": " ++ foldl step (strip r) rs ++ "."
       where strip = dropWhile isSpace . filter (/='\r')
             step accum = flip (++) $ "; " ++ accum

-- | TLS client parameters.
params :: ClientParams 
params = (defaultParamsClient "smtp.gmail.com" "587")
   { clientSupported  = def { supportedCiphers      = ciphersuite_all }
   , clientShared     = def { sharedValidationCache = noValidate      }
   } where noValidate = ValidationCache (\_ _ _ -> return ValidationCachePass)
                                        (\_ _ _ -> return ())

-- | Get the mime type for the given file extension.
getMime :: String -> Strict.Text
getMime = \ case
   ".3dm"       -> "x-world/x-3dmf"
   ".3dmf"      -> "x-world/x-3dmf"
   ".a"         -> "application/octet-stream"
   ".aab"       -> "application/x-authorware-bin"
   ".aam"       -> "application/x-authorware-map"
   ".aas"       -> "application/x-authorware-seg"
   ".abc"       -> "text/vnd.abc"
   ".acgi"      -> "text/html"
   ".afl"       -> "video/animaflex"
   ".ai"        -> "application/postscript"
   ".aif"       -> "audio/aiff"
   ".aifc"      -> "audio/aiff"
   ".aiff"      -> "audio/aiff"
   ".aim"       -> "application/x-aim"
   ".aip"       -> "text/x-audiosoft-intra"
   ".ani"       -> "application/x-navi-animation"
   ".aos"       -> "application/x-nokia-9000-communicator-add-on-software"
   ".aps"       -> "application/mime"
   ".arc"       -> "application/octet-stream"
   ".arj"       -> "application/arj"
   ".art"       -> "image/x-jg"
   ".asf"       -> "video/x-ms-asf"
   ".asm"       -> "text/x-asm"
   ".asp"       -> "text/asp"
   ".asx"       -> "application/x-mplayer2"
   ".au"        -> "audio/basic"
   ".avi"       -> "application/x-troff-msvideo"
   ".avs"       -> "video/avs-video"
   ".bcpio"     -> "application/x-bcpio"
   ".bin"       -> "application/mac-binary"
   ".bm"        -> "image/bmp"
   ".bmp"       -> "image/bmp"
   ".boo"       -> "application/book"
   ".book"      -> "application/book"
   ".boz"       -> "application/x-bzip2"
   ".bsh"       -> "application/x-bsh"
   ".bz"        -> "application/x-bzip"
   ".bz2"       -> "application/x-bzip2"
   ".c"         -> "text/plain"
   ".c++"       -> "text/plain"
   ".cat"       -> "application/vnd.ms-pki.seccat"
   ".cc"        -> "text/plain"
   ".ccad"      -> "application/clariscad"
   ".cco"       -> "application/x-cocoa"
   ".cdf"       -> "application/cdf"
   ".cer"       -> "application/pkix-cert"
   ".cha"       -> "application/x-chat"
   ".chat"      -> "application/x-chat"
   ".class"     -> "application/java"
   ".com"       -> "application/octet-stream"
   ".conf"      -> "text/plain"
   ".cpio"      -> "application/x-cpio"
   ".cpp"       -> "text/x-c"
   ".cpt"       -> "application/mac-compactpro"
   ".crl"       -> "application/pkcs-crl"
   ".crt"       -> "application/pkix-cert"
   ".csh"       -> "application/x-csh"
   ".css"       -> "application/x-pointplus"
   ".cxx"       -> "text/plain"
   ".dcr"       -> "application/x-director"
   ".deepv"     -> "application/x-deepv"
   ".def"       -> "text/plain"
   ".der"       -> "application/x-x509-ca-cert"
   ".dif"       -> "video/x-dv"
   ".dir"       -> "application/x-director"
   ".dl"        -> "video/dl"
   ".doc"       -> "application/msword"
   ".dot"       -> "application/msword"
   ".dp"        -> "application/commonground"
   ".drw"       -> "application/drafting"
   ".dump"      -> "application/octet-stream"
   ".dv"        -> "video/x-dv"
   ".dvi"       -> "application/x-dvi"
   ".dwf"       -> "drawing/x-dwf (old)"
   ".dwg"       -> "application/acad"
   ".dxf"       -> "application/dxf"
   ".dxr"       -> "application/x-director"
   ".el"        -> "text/x-script.elisp"
   ".elc"       -> "application/x-bytecode.elisp (compiled elisp)"
   ".env"       -> "application/x-envoy"
   ".eps"       -> "application/postscript"
   ".es"        -> "application/x-esrehber"
   ".etx"       -> "text/x-setext"
   ".evy"       -> "application/envoy"
   ".exe"       -> "application/octet-stream"
   ".f"         -> "text/plain"
   ".f77"       -> "text/x-fortran"
   ".f90"       -> "text/plain"
   ".fdf"       -> "application/vnd.fdf"
   ".fif"       -> "application/fractals"
   ".fli"       -> "video/fli"
   ".flo"       -> "image/florian"
   ".flx"       -> "text/vnd.fmi.flexstor"
   ".fmf"       -> "video/x-atomic3d-feature"
   ".for"       -> "text/plain"
   ".fpx"       -> "image/vnd.fpx"
   ".frl"       -> "application/freeloader"
   ".funk"      -> "audio/make"
   ".g"         -> "text/plain"
   ".g3"        -> "image/g3fax"
   ".gif"       -> "image/gif"
   ".gl"        -> "video/gl"
   ".gsd"       -> "audio/x-gsm"
   ".gsm"       -> "audio/x-gsm"
   ".gsp"       -> "application/x-gsp"
   ".gss"       -> "application/x-gss"
   ".gtar"      -> "application/x-gtar"
   ".gz"        -> "application/x-compressed"
   ".gzip"      -> "application/x-gzip"
   ".h"         -> "text/plain"
   ".hdf"       -> "application/x-hdf"
   ".help"      -> "application/x-helpfile"
   ".hgl"       -> "application/vnd.hp-hpgl"
   ".hh"        -> "text/plain"
   ".hlb"       -> "text/x-script"
   ".hlp"       -> "application/hlp"
   ".hpg"       -> "application/vnd.hp-hpgl"
   ".hpgl"      -> "application/vnd.hp-hpgl"
   ".hqx"       -> "application/binhex"
   ".hs"        -> "text/x-haskell"
   ".hta"       -> "application/hta"
   ".htc"       -> "text/x-component"
   ".htm"       -> "text/html"
   ".html"      -> "text/html"
   ".htmls"     -> "text/html"
   ".htt"       -> "text/webviewhtml"
   ".htx"       -> "text/html"
   ".ice"       -> "x-conference/x-cooltalk"
   ".ico"       -> "image/x-icon"
   ".idc"       -> "text/plain"
   ".ief"       -> "image/ief"
   ".iefs"      -> "image/ief"
   ".iges"      -> "application/iges"
   ".igs"       -> "application/iges"
   ".ima"       -> "application/x-ima"
   ".imap"      -> "application/x-httpd-imap"
   ".inf"       -> "application/inf"
   ".ins"       -> "application/x-internett-signup"
   ".ip"        -> "application/x-ip2"
   ".isu"       -> "video/x-isvideo"
   ".it"        -> "audio/it"
   ".iv"        -> "application/x-inventor"
   ".ivr"       -> "i-world/i-vrml"
   ".ivy"       -> "application/x-livescreen"
   ".jam"       -> "audio/x-jam"
   ".jav"       -> "text/plain"
   ".java"      -> "text/plain"
   ".jcm"       -> "application/x-java-commerce"
   ".jfif"      -> "image/jpeg"
   ".jfif-tbnl" -> "image/jpeg"
   ".jpe"       -> "image/jpeg"
   ".jpeg"      -> "image/jpeg"
   ".jpg"       -> "image/jpeg"
   ".jps"       -> "image/x-jps"
   ".js"        -> "application/x-javascript"
   ".jut"       -> "image/jutvision"
   ".kar"       -> "audio/midi"
   ".ksh"       -> "application/x-ksh"
   ".la"        -> "audio/nspaudio"
   ".lam"       -> "audio/x-liveaudio"
   ".latex"     -> "application/x-latex"
   ".lha"       -> "application/lha"
   ".lhx"       -> "application/octet-stream"
   ".list"      -> "text/plain"
   ".lma"       -> "audio/nspaudio"
   ".log"       -> "text/plain"
   ".lsp"       -> "application/x-lisp"
   ".lst"       -> "text/plain"
   ".lsx"       -> "text/x-la-asf"
   ".ltx"       -> "application/x-latex"
   ".lzh"       -> "application/octet-stream"
   ".lzx"       -> "application/lzx"
   ".m"         -> "text/plain"
   ".m1v"       -> "video/mpeg"
   ".m2a"       -> "audio/mpeg"
   ".m2v"       -> "video/mpeg"
   ".m3u"       -> "audio/x-mpequrl"
   ".man"       -> "application/x-troff-man"
   ".map"       -> "application/x-navimap"
   ".mar"       -> "text/plain"
   ".mbd"       -> "application/mbedlet"
   ".mc$"       -> "application/x-magic-cap-package-1.0"
   ".mcd"       -> "application/mcad"
   ".mcf"       -> "image/vasa"
   ".mcp"       -> "application/netmc"
   ".me"        -> "application/x-troff-me"
   ".mht"       -> "message/rfc822"
   ".mhtml"     -> "message/rfc822"
   ".mid"       -> "application/x-midi"
   ".midi"      -> "application/x-midi"
   ".mif"       -> "application/x-frame"
   ".mime"      -> "message/rfc822"
   ".mjf"       -> "audio/x-vnd.audioexplosion.mjuicemediafile"
   ".mjpg"      -> "video/x-motion-jpeg"
   ".mm"        -> "application/base64"
   ".mme"       -> "application/base64"
   ".mod"       -> "audio/mod"
   ".moov"      -> "video/quicktime"
   ".mov"       -> "video/quicktime"
   ".movie"     -> "video/x-sgi-movie"
   ".mp2"       -> "audio/mpeg"
   ".mp3"       -> "audio/mpeg3"
   ".mpa"       -> "audio/mpeg"
   ".mpc"       -> "application/x-project"
   ".mpe"       -> "video/mpeg"
   ".mpeg"      -> "video/mpeg"
   ".mpg"       -> "audio/mpeg"
   ".mpga"      -> "audio/mpeg"
   ".mpp"       -> "application/vnd.ms-project"
   ".mpt"       -> "application/x-project"
   ".mpv"       -> "application/x-project"
   ".mpx"       -> "application/x-project"
   ".mrc"       -> "application/marc"
   ".ms"        -> "application/x-troff-ms"
   ".mv"        -> "video/x-sgi-movie"
   ".my"        -> "audio/make"
   ".mzz"       -> "application/x-vnd.audioexplosion.mzz"
   ".nap"       -> "image/naplps"
   ".naplps"    -> "image/naplps"
   ".nc"        -> "application/x-netcdf"
   ".ncm"       -> "application/vnd.nokia.configuration-message"
   ".nif"       -> "image/x-niff"
   ".niff"      -> "image/x-niff"
   ".nix"       -> "application/x-mix-transfer"
   ".nsc"       -> "application/x-conference"
   ".nvd"       -> "application/x-navidoc"
   ".o"         -> "application/octet-stream"
   ".oda"       -> "application/oda"
   ".omc"       -> "application/x-omc"
   ".omcd"      -> "application/x-omcdatamaker"
   ".omcr"      -> "application/x-omcregerator"
   ".p"         -> "text/x-pascal"
   ".p10"       -> "application/pkcs10"
   ".p12"       -> "application/pkcs-12"
   ".p7a"       -> "application/x-pkcs7-signature"
   ".p7c"       -> "application/pkcs7-mime"
   ".p7m"       -> "application/pkcs7-mime"
   ".p7r"       -> "application/x-pkcs7-certreqresp"
   ".p7s"       -> "application/pkcs7-signature"
   ".part"      -> "application/pro_eng"
   ".pas"       -> "text/pascal"
   ".pbm"       -> "image/x-portable-bitmap"
   ".pcl"       -> "application/vnd.hp-pcl"
   ".pct"       -> "image/x-pict"
   ".pcx"       -> "image/x-pcx"
   ".pdb"       -> "chemical/x-pdb"
   ".pdf"       -> "application/pdf"
   ".pfunk"     -> "audio/make"
   ".pgm"       -> "image/x-portable-graymap"
   ".pic"       -> "image/pict"
   ".pict"      -> "image/pict"
   ".pkg"       -> "application/x-newton-compatible-pkg"
   ".pko"       -> "application/vnd.ms-pki.pko"
   ".pl"        -> "text/plain"
   ".plx"       -> "application/x-pixclscript"
   ".pm"        -> "image/x-xpixmap"
   ".pm4"       -> "application/x-pagemaker"
   ".pm5"       -> "application/x-pagemaker"
   ".png"       -> "image/png"
   ".pnm"       -> "application/x-portable-anymap"
   ".pot"       -> "application/mspowerpoint"
   ".pov"       -> "model/x-pov"
   ".ppa"       -> "application/vnd.ms-powerpoint"
   ".ppm"       -> "image/x-portable-pixmap"
   ".pps"       -> "application/mspowerpoint"
   ".ppt"       -> "application/mspowerpoint"
   ".ppz"       -> "application/mspowerpoint"
   ".pre"       -> "application/x-freelance"
   ".prt"       -> "application/pro_eng"
   ".ps"        -> "application/postscript"
   ".psd"       -> "application/octet-stream"
   ".pvu"       -> "paleovu/x-pv"
   ".pwz"       -> "application/vnd.ms-powerpoint"
   ".py"        -> "text/x-script.phyton"
   ".pyc"       -> "applicaiton/x-bytecode.python"
   ".qcp"       -> "audio/vnd.qcelp"
   ".qd3"       -> "x-world/x-3dmf"
   ".qd3d"      -> "x-world/x-3dmf"
   ".qif"       -> "image/x-quicktime"
   ".qt"        -> "video/quicktime"
   ".qtc"       -> "video/x-qtc"
   ".qti"       -> "image/x-quicktime"
   ".qtif"      -> "image/x-quicktime"
   ".ra"        -> "audio/x-pn-realaudio"
   ".ram"       -> "audio/x-pn-realaudio"
   ".ras"       -> "application/x-cmu-raster"
   ".rast"      -> "image/cmu-raster"
   ".rexx"      -> "text/x-script.rexx"
   ".rf"        -> "image/vnd.rn-realflash"
   ".rgb"       -> "image/x-rgb"
   ".rm"        -> "application/vnd.rn-realmedia"
   ".rmi"       -> "audio/mid"
   ".rmm"       -> "audio/x-pn-realaudio"
   ".rmp"       -> "audio/x-pn-realaudio"
   ".rng"       -> "application/ringing-tones"
   ".rnx"       -> "application/vnd.rn-realplayer"
   ".roff"      -> "application/x-troff"
   ".rp"        -> "image/vnd.rn-realpix"
   ".rpm"       -> "audio/x-pn-realaudio-plugin"
   ".rt"        -> "text/richtext"
   ".rtf"       -> "application/rtf"
   ".rtx"       -> "application/rtf"
   ".rv"        -> "video/vnd.rn-realvideo"
   ".s"         -> "text/x-asm"
   ".s3m"       -> "audio/s3m"
   ".saveme"    -> "application/octet-stream"
   ".sbk"       -> "application/x-tbook"
   ".scm"       -> "application/x-lotusscreencam"
   ".sdml"      -> "text/plain"
   ".sdp"       -> "application/sdp"
   ".sdr"       -> "application/sounder"
   ".sea"       -> "application/sea"
   ".set"       -> "application/set"
   ".sgm"       -> "text/sgml"
   ".sgml"      -> "text/sgml"
   ".sh"        -> "application/x-bsh"
   ".shar"      -> "application/x-bsh"
   ".shtml"     -> "text/html"
   ".sid"       -> "audio/x-psid"
   ".sit"       -> "application/x-sit"
   ".skd"       -> "application/x-koan"
   ".skm"       -> "application/x-koan"
   ".skp"       -> "application/x-koan"
   ".skt"       -> "application/x-koan"
   ".sl"        -> "application/x-seelogo"
   ".smi"       -> "application/smil"
   ".smil"      -> "application/smil"
   ".snd"       -> "audio/basic"
   ".sol"       -> "application/solids"
   ".spc"       -> "application/x-pkcs7-certificates"
   ".spl"       -> "application/futuresplash"
   ".spr"       -> "application/x-sprite"
   ".sprite"    -> "application/x-sprite"
   ".src"       -> "application/x-wais-source"
   ".ssi"       -> "text/x-server-parsed-html"
   ".ssm"       -> "application/streamingmedia"
   ".sst"       -> "application/vnd.ms-pki.certstore"
   ".step"      -> "application/step"
   ".stl"       -> "application/sla"
   ".stp"       -> "application/step"
   ".sv4cpio"   -> "application/x-sv4cpio"
   ".sv4crc"    -> "application/x-sv4crc"
   ".svf"       -> "image/vnd.dwg"
   ".svr"       -> "application/x-world"
   ".swf"       -> "application/x-shockwave-flash"
   ".t"         -> "application/x-troff"
   ".talk"      -> "text/x-speech"
   ".tar"       -> "application/x-tar"
   ".tbk"       -> "application/toolbook"
   ".tcl"       -> "application/x-tcl"
   ".tcsh"      -> "text/x-script.tcsh"
   ".tex"       -> "application/x-tex"
   ".texi"      -> "application/x-texinfo"
   ".texinfo"   -> "application/x-texinfo"
   ".text"      -> "application/plain"
   ".tgz"       -> "application/gnutar"
   ".tif"       -> "image/tiff"
   ".tiff"      -> "image/tiff"
   ".tr"        -> "application/x-troff"
   ".tsi"       -> "audio/tsp-audio"
   ".tsp"       -> "application/dsptype"
   ".tsv"       -> "text/tab-separated-values"
   ".turbot"    -> "image/florian"
   ".txt"       -> "text/plain"
   ".uil"       -> "text/x-uil"
   ".uni"       -> "text/uri-list"
   ".unis"      -> "text/uri-list"
   ".unv"       -> "application/i-deas"
   ".uri"       -> "text/uri-list"
   ".uris"      -> "text/uri-list"
   ".ustar"     -> "application/x-ustar"
   ".uu"        -> "application/octet-stream"
   ".uue"       -> "text/x-uuencode"
   ".vcd"       -> "application/x-cdlink"
   ".vcs"       -> "text/x-vcalendar"
   ".vda"       -> "application/vda"
   ".vdo"       -> "video/vdo"
   ".vew"       -> "application/groupwise"
   ".viv"       -> "video/vivo"
   ".vivo"      -> "video/vivo"
   ".vmd"       -> "application/vocaltec-media-desc"
   ".vmf"       -> "application/vocaltec-media-file"
   ".voc"       -> "audio/voc"
   ".vos"       -> "video/vosaic"
   ".vox"       -> "audio/voxware"
   ".vqe"       -> "audio/x-twinvq-plugin"
   ".vqf"       -> "audio/x-twinvq"
   ".vql"       -> "audio/x-twinvq-plugin"
   ".vrml"      -> "application/x-vrml"
   ".vrt"       -> "x-world/x-vrt"
   ".vsd"       -> "application/x-visio"
   ".vst"       -> "application/x-visio"
   ".vsw"       -> "application/x-visio"
   ".w60"       -> "application/wordperfect6.0"
   ".w61"       -> "application/wordperfect6.1"
   ".w6w"       -> "application/msword"
   ".wav"       -> "audio/wav"
   ".wb1"       -> "application/x-qpro"
   ".wbmp"      -> "image/vnd.wap.wbmp"
   ".web"       -> "application/vnd.xara"
   ".wiz"       -> "application/msword"
   ".wk1"       -> "application/x-123"
   ".wmf"       -> "windows/metafile"
   ".wml"       -> "text/vnd.wap.wml"
   ".wmlc"      -> "application/vnd.wap.wmlc"
   ".wmls"      -> "text/vnd.wap.wmlscript"
   ".wmlsc"     -> "application/vnd.wap.wmlscriptc"
   ".word"      -> "application/msword"
   ".wp"        -> "application/wordperfect"
   ".wp5"       -> "application/wordperfect"
   ".wp6"       -> "application/wordperfect"
   ".wpd"       -> "application/wordperfect"
   ".wq1"       -> "application/x-lotus"
   ".wri"       -> "application/mswrite"
   ".wrl"       -> "application/x-world"
   ".wrz"       -> "model/vrml"
   ".wsc"       -> "text/scriplet"
   ".wsrc"      -> "application/x-wais-source"
   ".wtk"       -> "application/x-wintalk"
   ".xbm"       -> "image/x-xbitmap"
   ".xdr"       -> "video/x-amt-demorun"
   ".xgz"       -> "xgl/drawing"
   ".xif"       -> "image/vnd.xiff"
   ".xl"        -> "application/excel"
   ".xla"       -> "application/excel"
   ".xlb"       -> "application/excel"
   ".xlc"       -> "application/excel"
   ".xld"       -> "application/excel"
   ".xlk"       -> "application/excel"
   ".xll"       -> "application/excel"
   ".xlm"       -> "application/excel"
   ".xls"       -> "application/excel"
   ".xlt"       -> "application/excel"
   ".xlv"       -> "application/excel"
   ".xlw"       -> "application/excel"
   ".xm"        -> "audio/xm"
   ".xml"       -> "application/xml"
   ".xmz"       -> "xgl/movie"
   ".xpix"      -> "application/x-vnd.ls-xpix"
   ".xpm"       -> "image/x-xpixmap"
   ".x-png"     -> "image/png"
   ".xsr"       -> "video/x-amt-showrun"
   ".xwd"       -> "image/x-xwd"
   ".xyz"       -> "chemical/x-pdb"
   ".z"         -> "application/x-compress"
   ".zip"       -> "application/x-compressed"
   ".zoo"       -> "application/octet-stream"
   ".zsh"       -> "text/x-script.zsh"
   _            -> "application/octet-stream"
