// Foundation's legacy string `Scanner` shadows TiesCore's research `Scanner` in every file
// that imports both — which is nearly all of the app — and `TiesCore.Scanner` doesn't
// disambiguate it either, because TiesCore also declares an enum named `TiesCore`.
//
// This file imports nothing but TiesCore, so the name resolves here; the rest of the app
// refers to the research scanner through this alias.
import TiesCore

typealias ResearchScanner = Scanner
