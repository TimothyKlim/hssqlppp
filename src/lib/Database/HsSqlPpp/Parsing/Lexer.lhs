
This file contains the lexer for sql source text.

Lexicon:

~~~~
string
identifier or keyword
symbols - operators and ;,()[]
positional arg
int
float
copy payload (used to lex copy from stdin data)
~~~~

> module Database.HsSqlPpp.Parsing.Lexer (
>               Token
>              ,Tok(..)
>              ,lexSqlFile
>              ,lexSqlText
>              ,lexSqlTextWithPosition
>              ,identifierString
>              ,LexState
>              ) where
> import Text.Parsec hiding(many, optional, (<|>))
> import qualified Text.Parsec.Token as P
> import Text.Parsec.Language
> --import Text.Parsec.String
> import Text.Parsec.Pos
>
> import Control.Applicative
> import Control.Monad.Identity
>
> import Database.HsSqlPpp.Parsing.ParseErrors
> import Database.HsSqlPpp.Utils.Utils
> -- import Database.HsSqlPpp.Ast.Name

================================================================================

= data types

> type Token = (SourcePos, Tok)
>
> data Tok = StringTok String String --delim, value (delim will one of
>                                    --', $$, $[stuff]$

>          | IdStringTok String -- either a identifier component (without .) or a *

>          | SymbolTok String -- operators, and ()[],;: and also .
>                             -- '*' is currently always lexed as an id
>                             --   rather than an operator
>                             -- this gets fixed in the parsing stage

>          | PositionalArgTok Integer -- used for $1, etc.

>          | FloatTok Double
>          | IntegerTok Integer
>          | CopyPayloadTok String -- support copy from stdin; with inline data
>            deriving (Eq,Show)
>
> type LexState = [Tok]
>
> lexSqlFile :: FilePath -> IO (Either ParseErrorExtra [Token])
> lexSqlFile f = do
>   te <- readFile f
>   let x = runParser sqlTokens [] f te
>   return $ toParseErrorExtra x Nothing te
>
> lexSqlText :: String -> String -> Either ParseErrorExtra [Token]
> lexSqlText f s = toParseErrorExtra (runParser sqlTokens [] f s) Nothing s
>
> lexSqlTextWithPosition :: String -> Int -> Int -> String
>                        -> Either ParseErrorExtra [Token]
> lexSqlTextWithPosition f l c s =
>   toParseErrorExtra (runParser (do
>                                 setPosition (newPos f l c)
>                                 sqlTokens) [] f s) (Just (l,c)) s

================================================================================

= lexers

lexer for tokens, contains a hack for copy from stdin with inline
table data.

> sqlTokens :: ParsecT String LexState Identity [Token]
> sqlTokens =
>   setState [] >>
>   whiteSpace >>
>   many sqlToken <* eof

Lexer for an individual token.

What we could do is lex lazily and when the lexer reads a copy from
stdin statement, it switches lexers to lex the inline table data, then
switches back. Don't know how to do this in parsec, or even if it is
possible, so as a work around, we use the state to trap if we've just
seen 'from stdin;', if so, we read the copy payload as one big token,
otherwise we read a normal token.

> sqlToken :: ParsecT String LexState Identity Token
> sqlToken = do
>            sp <- getPosition
>            sta <- getState
>            t <- if sta == [ft,st,mt]
>                 then copyPayload
>                 else try sqlString
>                  <|> try idString
>                  <|> try positionalArg
>                  <|> try sqlSymbol
>                  <|> try sqlFloat
>                  <|> try sqlInteger
>            updateState $ \stt ->
>              case () of
>                      _ | stt == [] && t == ft -> [ft]
>                        | stt == [ft] && t == st -> [ft,st]
>                        | stt == [ft,st] && t == mt -> [ft,st,mt]
>                        | otherwise -> []
>
>            return (sp,t)
>            where
>              ft = IdStringTok "from"
>              st = IdStringTok "stdin"
>              mt = SymbolTok ";"

== specialized token parsers

> sqlString :: ParsecT String LexState Identity Tok
> sqlString = stringQuotes <|> stringLD
>   where
>     --parse a string delimited by single quotes
>     stringQuotes = StringTok "\'" <$> stringPar
>     stringPar = optional (char 'E') *> char '\''
>                 *> readQuoteEscape <* whiteSpace
>     --(readquoteescape reads the trailing ')

have to read two consecutive single quotes as a quote character
instead of the end of the string, probably an easier way to do this

other escapes (e.g. \n \t) are left unprocessed

>     readQuoteEscape = do
>                       x <- anyChar
>                       if x == '\''
>                         then try ((x:) <$> (char '\'' *> readQuoteEscape))
>                              <|> return ""
>                         else (x:) <$> readQuoteEscape

parse a dollar quoted string

>     stringLD = do
>                -- cope with $$ as well as $[identifier]$
>                tag <- try (char '$' *> ((char '$' *> return "")
>                                    <|> (identifierString <* char '$')))
>                s <- lexeme $ manyTill anyChar
>                       (try $ char '$' <* string tag <* char '$')
>                return $ StringTok ("$" ++ tag ++ "$") s
>
> idString :: ParsecT String LexState Identity Tok
> idString = IdStringTok <$> identifierString
>
> positionalArg :: ParsecT String LexState Identity Tok
> positionalArg = char '$' >> PositionalArgTok <$> integer


Lexing symbols:

~~~~
approach 1:
try to keep multi symbol operators as single lexical items
(e.g. "==", "~=="

approach 2:
make each character a separate element
e.g. == lexes to ['=', '=']
then the parser sorts this out

Sort of using approach 1 at the moment, see below

== notes on symbols in pg operators
pg symbols can be made from:

=_*/<>=~!@#%^&|`?

no --, /* in symbols

can't end in + or - unless contains
~!@#%^&|?

Most of this isn't relevant for the current lexer.

== sql symbols for this lexer:

sql symbol is one of
()[],; - single character
+-*/<>=~!@#%^&|`? string - one or more of these, parsed until hit char
which isn't one of these (including whitespace). This will parse some
standard sql expressions wrongly at the moment, work around is to add
whitespace e.g. i think 3*-4 is valid sql, should lex as '3' '*' '-'
'4', but will currently lex as '3' '*-' '4'. This is planned to be
fixed in the parser.
.. := :: : - other special cases
A single * will lex as an identifier rather than a symbol, the parser
deals with this.

~~~~

> sqlSymbol :: ParsecT String LexState Identity Tok
> sqlSymbol =
>   SymbolTok <$> lexeme (choice [
>                          replicate 1 <$> oneOf "()[],;"
>                         ,try $ string ".."
>                         ,string "."
>                         ,try $ string "::"
>                         ,try $ string ":="
>                         ,string ":"
>                         ,try $ string "$(" -- antiquote standard splice
>                         ,try $ string "$s(" -- antiquote string splice
>                         ,string "$i(" -- antiquote identifier splice
>                         ,many1 (oneOf "+-*/<>=~!@#%^&|`?")
>                         ])
>
> sqlFloat :: ParsecT String LexState Identity Tok
> sqlFloat = FloatTok <$> float
>
> sqlInteger :: ParsecT String LexState Identity Tok
> sqlInteger = IntegerTok <$> integer

================================================================================

additional parser bits and pieces

include dots, * in all identifier strings during lexing. This parser
is also used for keywords, so identifiers and keywords aren't
distinguished until during proper parsing, and * and qualifiers aren't
really examined until type checking

> identifierString :: ParsecT String LexState Identity String
> identifierString = lexeme $ choice [
>                     "*" <$ symbol "*"
>                    ,nonStarPart]
>   where
>     nonStarPart = idpart <|> (char '"' *> many (noneOf "\"") <* char '"')
>                   where idpart = (letter <|> char '_') <:> secondOnwards
>     secondOnwards = many (alphaNum <|> char '_')

parse the block of inline data for a copy from stdin, ends with \. on
its own on a line

> copyPayload :: ParsecT String LexState Identity Tok
> copyPayload = CopyPayloadTok <$> lexeme (getLinesTillMatches "\\.\n")
>   where
>     getLinesTillMatches s = do
>                             x <- getALine
>                             if x == s
>                               then return ""
>                               else (x++) <$> getLinesTillMatches s
>     getALine = (++"\n") <$> manyTill anyChar (try newline)
>
> {-tryMaybeP :: GenParser tok st a
>           -> ParsecT [tok] st Identity (Maybe a)
> tryMaybeP p = try (optionMaybe p) <|> return Nothing-}

================================================================================

= parsec pass throughs

> symbol :: String -> ParsecT String LexState Identity String
> symbol = P.symbol lexer
>
> integer :: ParsecT String LexState Identity Integer
> integer = lexeme $ P.integer lexer
>
> float :: ParsecT String LexState Identity Double
> float = lexeme $ P.float lexer
>
> whiteSpace :: ParsecT String LexState Identity ()
> whiteSpace= P.whiteSpace lexer
>
> lexeme :: ParsecT String LexState Identity a
>           -> ParsecT String LexState Identity a
> lexeme = P.lexeme lexer

this lexer isn't really used as much as it could be, probably some of
the fields are not used at all (like identifier and operator stuff)

> lexer :: P.GenTokenParser String LexState Identity
> lexer = P.makeTokenParser (emptyDef {
>                             P.commentStart = "/*"
>                            ,P.commentEnd = "*/"
>                            ,P.commentLine = "--"
>                            ,P.nestedComments = False
>                            ,P.identStart = letter <|> char '_'
>                            ,P.identLetter    = alphaNum <|> oneOf "_"
>                            ,P.opStart        = P.opLetter emptyDef
>                            ,P.opLetter       = oneOf opLetters
>                            ,P.reservedOpNames= []
>                            ,P.reservedNames  = []
>                            ,P.caseSensitive  = False
>                            })
>
> opLetters :: String
> opLetters = ".:^*/%+-<>=|!"