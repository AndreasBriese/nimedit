
import
  compiler/ast, compiler/modules, compiler/passes, compiler/passaux,
  compiler/condsyms, compiler/options, compiler/sem, compiler/semdata,
  compiler/llstream, compiler/vm, compiler/vmdef, compiler/commands,
  compiler/msgs, compiler/magicsys, compiler/idents,
  compiler/astalgo, compiler/modulegraphs

from compiler/scriptconfig import setupVM

import os, strutils
import themes, styles, nimscript/common

proc raiseVariableError(ident, typ: string) {.noinline.} =
  raise newException(ValueError,
    "NimScript's variable '" & ident & "' needs a value of type '" & typ & "'.")

proc isStrLit(n: PNode): bool = n.kind in {nkStrLit..nkTripleStrLit}
proc isIntLit(n: PNode): bool = n.kind in {nkCharLit..nkUInt64Lit}

proc getIdent(n: PNode): int =
  if n.kind == nkIdent: n.ident.id
  elif n.kind == nkSym: n.sym.name.id
  else: -1

var identCache* = newIdentCache()
var gConfig* = newConfigRef()
var moduleGraph = newModuleGraph(identCache, gConfig)

var
  actionsModule, colorsModule: PSym

proc getAction(x: string): PSym = strTableGet(actionsModule.tab, getIdent(identCache, x))

proc getGlobal(varname, field: string): PNode =
  let n = PCtx(moduleGraph.vm).getGlobalValue(getNimScriptSymbol(moduleGraph, varname))
  if n.kind != nkObjConstr:
    raiseVariableError(varname, "object")
  for i in 1 ..< n.len:
    let it = n[i]
    if getIdent(it[0]) == getIdent(identCache, field).id: return it[1]

proc getGlobal(varname, field: string; result: var int) =
  let n = getGlobal(varname, field)
  if n != nil and n.isIntLit:
    result = int(n.intVal)
  else:
    raiseVariableError(varname & "." & field, "int")

proc getGlobal(varname, field: string; result: var byte) =
  let n = getGlobal(varname, field)
  if n != nil and n.isIntLit and n.intVal <% 256:
    result = byte(n.intVal)
  else:
    raiseVariableError(varname & "." & field, "byte")

proc getGlobal(varname, field: string; result: var bool) =
  let n = getGlobal(varname, field)
  if n != nil and n.isIntLit:
    result = n.intVal != 0
  else:
    raiseVariableError(varname & "." & field, "bool")

proc getGlobal(varname, field: string; result: var string) =
  let n = getGlobal(varname, field)
  if n != nil and n.isStrLit:
    result = if n.strVal.isNil: "" else: n.strVal
  else:
    raiseVariableError(varname & "." & field, "string")

proc getGlobal(varname, field: string; result: var type(parseColor"")) =
  let n = getGlobal(varname, field)
  if n != nil and n.isIntLit:
    result = colorFromInt(n.intVal)
  else:
    raiseVariableError(varname & "." & field, "Color")

proc extractStyles(result: var StyleManager; fm: var FontManager;
                   fontSize: byte; fontName: string) =
  let n = PCtx(moduleGraph.vm).getGlobalValue(getNimScriptSymbol(moduleGraph, "tokens"))
  if n.kind == nkBracket and n.len == int(high(TokenClass))+1:
    for i, x in n.sons:
      if x.kind in {nkTupleConstr, nkPar} and x.len == 2 and x[0].isIntLit and x[1].isIntLit:
        let style = FontStyle(x[1].intVal)
        result.a[TokenClass(i)] = Style(
            font: fontByName(fm, fontName, fontSize, style),
            attr: FontAttr(color: colorFromInt(x[0].intVal),
                           style: style,
                           size: fontSize))
      else:
        raiseVariableError("tokens", "array[TokenClass, (Color, FontStyle)]")
  else:
    raiseVariableError("tokens", "array[TokenClass, (Color, FontStyle)]")

proc detectNimLib(): string =
  let nimlibCfg = os.getAppDir() / "nimlib.cfg"
  result = ""
  if fileExists(nimlibCfg):
    result = readFile(nimlibCfg).strip
    if not fileExists(result / "system.nim"): result.setlen 0
  if result.len == 0:
    let nimexe = os.findExe("nim")
    if nimexe.len == 0: quit "cannot find Nim's stdlib location"
    result = nimexe.splitPath()[0] /../ "lib"
    if not fileExists(result / "system.nim"):
      when defined(unix):
        try:
          result = nimexe.expandSymlink.splitPath()[0] /../ "lib"
        except OSError:
          quit "cannot find Nim's stdlib location"
      if not fileExists(result / "system.nim"):
        quit "cannot find Nim's stdlib location"

proc setupNimscript*(colorsScript: string): PEvalContext =
  let config = moduleGraph.config
  config.libpath = detectNimLib()
  add(config.searchPaths, config.libpath)
  add(config.searchPaths, config.libpath / "pure")

  initDefines(config.symbols)
  defineSymbol(config.symbols, "nimscript")
  defineSymbol(config.symbols, "nimconfig")

  registerPass(moduleGraph, semPass)
  registerPass(moduleGraph, evalPass)

  colorsModule = makeModule(moduleGraph, colorsScript)
  incl(colorsModule.flags, sfMainModule)
  moduleGraph.vm = setupVM(colorsModule, identCache, colorsScript, moduleGraph)
  compileSystemModule(moduleGraph)
  result = PCtx(moduleGraph.vm)

proc compileActions*(actionsScript: string) =
  ## Compiles the actions module for the first time.
  actionsModule = makeModule(moduleGraph, actionsScript)
  processModule(moduleGraph, actionsModule, llStreamOpen(actionsScript, fmRead))

proc reloadActions*(actionsScript: string) =
  #resetModule(actionsModule)
  processModule(moduleGraph, actionsModule, llStreamOpen(actionsScript, fmRead))

proc execProc*(procname: string) =
  let a = getAction(procname)
  if a != nil:
    discard vm.execProc(PCtx(moduleGraph.vm), a, [])

proc supportsAction*(procname: string): bool = getAction(procname) != nil

proc runTransformator*(procname, selectedText: string): string =
  let a = getAction(procname)
  if a != nil:
    let res = vm.execProc(PCtx(moduleGraph.vm), a, [newStrNode(nkStrLit, selectedText)])
    if res.isStrLit:
      result = res.strVal

proc loadTheme*(colorsScript: string; result: var InternalTheme;
                sm: var StyleManager; fm: var FontManager) =
  let m = colorsModule
  #resetModule(m)

  processModule(moduleGraph, m, llStreamOpen(colorsScript, fmRead))

  template trivialField(field) =
    getGlobal("theme", astToStr field, result.field)

  template trivialField(externalName, field) =
    getGlobal("theme", externalName, result.field)


  getGlobal("theme", "uiActiveElement", result.active[true])
  getGlobal("theme", "uiInactiveElement", result.active[false])

  getGlobal("theme", "selected", sm.b[mcSelected])
  getGlobal("theme", "highlighted", sm.b[mcHighlighted])

  trivialField "background", bg
  trivialField "foreground", fg
  trivialField cursor
  trivialField cursorWidth
  trivialField uiXGap
  trivialField uiYGap
  trivialField editorFont
  trivialField editorFontSize
  trivialField uiFont
  trivialField uiFontSize
  trivialField tabWidth
  trivialField consoleAfter
  trivialField consoleWidth
  trivialField lines
  trivialField showLines
  trivialField bracket
  trivialField showBracket
  trivialField showIndentation
  trivialField indentation
  trivialField showMinimap
  trivialField showLigatures
  trivialField nimsuggestPath

  let fontName = if result.editorFont.len > 0: result.editorFont
                 else: "DejaVuSansMono"
  extractStyles sm, fm, result.editorFontSize, fontName
