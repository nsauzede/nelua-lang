local Traverser = require 'euluna.traverser'
local Coder = require 'euluna.coder'
local class = require 'pl.class'
local assertf = require 'euluna.utils'.assertf

local Builtins = {}

local NUM_LITERALS = {
  _integer    = 'integer',
  _number     = 'number',
  _b          = 'byte',     _byte       = 'byte',
  _c          = 'char',     _char       = 'char',
  _i          = 'int',      _int        = 'int',
  _i8         = 'int8',     _int8       = 'int8',
  _i16        = 'int16',    _int16      = 'int16',
  _i32        = 'int32',    _int32      = 'int32',
  _i64        = 'int64',    _int64      = 'int64',
  _u          = 'uint',     _uint       = 'uint',
  _u8         = 'uint',     _uint8      = 'uint',
  _u16        = 'uint',     _uint16     = 'uint',
  _u32        = 'uint',     _uint32     = 'uint',
  _u64        = 'uint',     _uint64     = 'uint',
  _f32        = 'float32',  _float32    = 'float32',
  _f64        = 'float64',  _float64    = 'float64',
  _pointer    = 'pointer',
}

local function get_number_type(ast)
  local numtype, _, literal = ast:args()
  if literal then
    local littype = NUM_LITERALS[literal]
    ast:assertf(littype, 'literal "%s" is not defined', literal)
    return littype
  end
  if numtype == 'int' then
    return 'int'
  elseif numtype == 'dec' then
    return 'number'
  elseif numtype == 'exp' then
    return 'number'
  elseif numtype == 'hex' then
    return 'uint'
  elseif numtype == 'bin' then
    return 'uint'
  end
end

function Builtins.euluna_string_t(context)
  context:add_include("<stdint.h>")
  context.builtins_declarations_coder:add(
[[typedef struct euluna_string_t {
    uintptr_t len;
    uintptr_t res;
    char data[];
} euluna_string_t;
]])
end

local BultinFunctions = {}

local PRINTF_TYPES_FORMAT = {
  integer = '%lli',
  number  = '%lf',
  byte    = '%hhi',
  char    = '%c',
  float64 = '%f',
  float32 = '%lf',
  pointer = '%p',
  int     = '%ti',
  int8    = '%hhi',
  int16   = '%hi',
  int32   = '%li',
  int64   = '%lli',
  uint    = '%tu',
  uint8   = '%hhu',
  uint16  = '%hu',
  uint32  = '%lu',
  uint64  = '%llu',
}

function BultinFunctions.print(context, ast, coder)
  local argtypes, args = ast:args()
  local funcname = '__euluna_print_' .. ast.pos
  context:add_builtin('euluna_string_t')
  context:add_include("<stdio.h>")

  local function add_heading(dcoder)
    dcoder:add('void ', funcname, '(')
    for i,arg in ipairs(args) do
      arg:assertf(arg.tag == 'String' or arg.tag == 'Number',
       "only string/number literals are supported in print")
      if i>1 then dcoder:add(', ') end
      if arg.tag == 'String' then
        dcoder:add('const euluna_string_t* a', i)
      elseif arg.tag == 'Number' then
        local tyname = get_number_type(arg)
        local ctype = context:get_ctype(arg, tyname)
        dcoder:add('const ', ctype, ' a', i)
      end
    end
    dcoder:add(')')
  end

  do
    local dcoder = context.declarations_coder
    dcoder:add_indent('inline ')
    add_heading(dcoder)
    dcoder:add_ln(';')
  end

  do
    local dcoder = context.definitions_coder
    dcoder:add_indent()
    add_heading(dcoder)
    dcoder:add_ln(' {')
    dcoder:inc_indent()
    for i,arg in ipairs(args) do
      if i > 1 then
        dcoder:add_indent_ln('fwrite("\t", 1, 1, stdout);')
      end
      if arg.tag == 'String' then
        dcoder:add_indent_ln('fwrite(a',i,'->data, a',i,'->len, 1, stdout);')
      elseif arg.tag == 'Number' then
        local tyname = get_number_type(arg)
        local tyformat = PRINTF_TYPES_FORMAT[tyname]
        ast:assertf(tyformat, 'invalid type "%s" for printf format', tyname)
        dcoder:add_indent_ln('fprintf(stdout, "',tyformat,'", a',i,');')
      end
    end
    dcoder:add_indent_ln('fwrite("\\n", 1, 1, stdout);')
    dcoder:add_indent_ln('fflush(stdout);')
    dcoder:dec_indent()
    dcoder:add_ln('}')
  end

  coder:add(funcname, '(')
  for i,arg in ipairs(args) do
    if i>1 then coder:add(', ') end
    if arg.tag == 'String' then
      coder:add('(euluna_string_t*) &', arg)
    elseif arg.tag == 'Number' then
      coder:add(arg)
    end
  end
  coder:add(')')
end

--------------------------------------------------------------------------------
-- Generator Context
--------------------------------------------------------------------------------
local GeneratorContext = class(Traverser.Context)

function GeneratorContext:_init(traverser)
  self:super(traverser)
  self.includes = {}
  self.builtins = {}
end

function GeneratorContext:add_include(name)
  local includes = self.includes
  if includes[name] then return end
  includes[name] = true
  self.includes_coder:add_ln(string.format('#include %s', name))
end

function GeneratorContext:add_builtin(name)
  local builtins = self.builtins
  if builtins[name] then return end
  builtins[name] = true
  local builtin = Builtins[name]
  assertf(builtin, 'builtin %s not found', name)
  builtin(self)
end

local C_PRIMTYPES = {
  integer = {ctype = 'int64_t',       include='<stdint.h>'},
  number  = {ctype = 'double',                            },
  byte    = {ctype = 'unsigned char',                     },
  char    = {ctype = 'char',                              },
  float64 = {ctype = 'double',                            },
  float32 = {ctype = 'float',                             },
  pointer = {ctype = 'void*',                             },
  int     = {ctype = 'intptr_t',      include='<stdint.h>'},
  int8    = {ctype = 'int8_t',        include='<stdint.h>'},
  int16   = {ctype = 'int16_t',       include='<stdint.h>'},
  int32   = {ctype = 'int32_t',       include='<stdint.h>'},
  int64   = {ctype = 'int64_t',       include='<stdint.h>'},
  uint    = {ctype = 'uintptr_t',     include='<stdint.h>'},
  uint8   = {ctype = 'uint8_t',       include='<stdint.h>'},
  uint16  = {ctype = 'uint16_t',      include='<stdint.h>'},
  uint32  = {ctype = 'uint32_t',      include='<stdint.h>'},
  uint64  = {ctype = 'uint64_t',      include='<stdint.h>'},
  boolean = {ctype = 'bool',          include='<stdbool.h>'},
  bool    = {ctype = 'bool',          include='<stdbool.h>'},
}

function GeneratorContext:get_ctype(ast, tyname)
  local ttype = C_PRIMTYPES[tyname]
  ast:assertf(ttype, 'type %s is not known', tyname)
  if ttype.include then
    self:add_include(ttype.include)
  end
  return ttype.ctype
end

--------------------------------------------------------------------------------
-- Generator
--------------------------------------------------------------------------------
local generator = Traverser()
generator.Context = GeneratorContext

generator:register('Number', function(context, ast, coder)
  local numtype, value, literal = ast:args()
  local cval
  if numtype == 'int' then
    cval = value
  elseif numtype == 'dec' then
    cval = value
  elseif numtype == 'exp' then
    cval = string.format('%se%s', value[1], value[2])
  elseif numtype == 'hex' then
    cval = string.format('0x%su', value)
  elseif numtype == 'bin' then
    cval = string.format('%uu', tonumber(value, 2))
  end
  if literal then
    local tyname = get_number_type(ast)
    local ctype = context:get_ctype(ast, tyname)
    coder:add('((', ctype, ') ', cval, ')')
  else
    coder:add(cval)
  end
end)

generator:register('String', function(context, ast, coder)
  local value, literal = ast:args()
  ast:assertf(literal == nil, 'literals are not supported yet')
  local deccoder = context.declarations_coder
  local len = #value
  local varname = '__string_literal_' .. ast.pos
  context:add_include('<stdint.h>')
  deccoder:add_indent('static const struct { uintptr_t len, res; char data[')
  deccoder:add(len + 1)
  deccoder:add_ln(']; }')
  deccoder:add_indent('  ', varname, ' = {', len, ', ', len, ', ')
  deccoder:add_double_quoted(value)
  deccoder:add_ln('};')
  coder:add(varname)
end)

generator:register('Boolean', function(context, ast, coder)
  local value = ast:args()
  context:add_include('<stdbool.h>')
  coder:add(tostring(value))
end)

-- TODO: Nil
-- TODO: Varargs
-- TODO: Table
-- TODO: Pair
-- TODO: Function

-- identifier and types
generator:register('Id', function(_, ast, coder)
  local name = ast:args()
  coder:add(name)
end)
generator:register('Paren', function(_, ast, coder)
  local what = ast:args()
  coder:add('(', what, ')')
end)
generator:register('Type', function(context, ast, coder)
  local tyname = ast:args()
  local ctyname = context:get_ctype(ast, tyname)
  coder:add(ctyname)
end)
generator:register('TypedId', function(_, ast, coder)
  local name, type = ast:args()
  if type then
    coder:add(type, ' ', name)
  else
    coder:add(name)
  end
end)

-- indexing
generator:register('DotIndex', function(_, ast, coder)
  local name, obj = ast:args()
  coder:add(obj, '.', name)
end)

-- TODO: ColonIndex

generator:register('ArrayIndex', function(_, ast, coder)
  local index, obj = ast:args()
  coder:add(obj, '[', index, ']')
end)

-- calls
generator:register('Call', function(context, ast, coder)
  local argtypes, args, caller, block_call = ast:args()
  if block_call then coder:add_indent() end
  local builtin
  if caller.tag == 'Id' then
    local fname = caller[1]
    builtin = BultinFunctions[fname]
  end
  if builtin then
    builtin(context, ast, coder)
  else
    coder:add(caller, '(', args, ')')
  end
  if block_call then coder:add_ln(";") end
end)

generator:register('CallMethod', function(_, ast, coder)
  local name, argtypes, args, caller, block_call = ast:args()
  if block_call then coder:add_indent() end
  coder:add(caller, '.', name, '(', caller, args, ')')
  if block_call then coder:add_ln() end
end)

generator:register('FuncArg', function(_, ast, coder)
  local name, mut, type = ast:args()
  ast:assertf(mut == nil or mut == 'var', "variable mutabilities are not supported yet")
  coder:add(type, ' ', name)
end)

-- block
generator:register('Block', function(context, ast, coder, scope)
  local stats = ast:args()
  local is_top_scope = scope:is_top()
  if is_top_scope then
    coder:inc_indent()
    coder:add_ln("int main() {")
  end
  coder:inc_indent()
  local inner_scope = context:push_scope()
  coder:add_traversal_list(stats, '')
  if inner_scope:is_main() and not inner_scope.has_return then
    -- main() must always return an integer
    coder:add_indent_ln("return 0;")
  end
  context:pop_scope()
  coder:dec_indent()
  if is_top_scope then
    coder:add_ln("}")
    coder:dec_indent()
  end
end)

-- statements
generator:register('Return', function(_, ast, coder, scope)
  --TODO: multiple return
  scope.has_return = true
  local rets = ast:args()
  ast:assertf(#rets <= 1, "multiple returns not supported yet")
  coder:add_indent("return")
  if #rets > 0 then
    coder:add_ln(' ', rets, ';')
  else
    if scope:is_main() then
      -- main() must always return an integer
      coder:add(' 0')
    end
    coder:add_ln(';')
  end
end)

generator:register('If', function(_, ast, coder)
  local ifparts, elseblock = ast:args()
  for i,ifpart in ipairs(ifparts) do
    local cond, block = ifpart[1], ifpart[2]
    if i == 1 then
      coder:add_indent("if(")
      coder:add(cond)
      coder:add_ln(") {")
    else
      coder:add_indent("} else if(")
      coder:add(cond)
      coder:add_ln(") {")
    end
    coder:add(block)
  end
  if elseblock then
    coder:add_indent_ln("} else {")
    coder:add(elseblock)
  end
  coder:add_indent_ln("}")
end)

generator:register('Switch', function(_, ast, coder)
  local val, caseparts, switchelseblock = ast:args()
  coder:add_indent_ln("switch(", val, ") {")
  coder:inc_indent()
  ast:assertf(#caseparts > 0, "switch must have case parts")
  for _,casepart in ipairs(caseparts) do
    local caseval, caseblock = casepart[1], casepart[2]
    coder:add_indent_ln("case ", caseval, ': {')
    coder:add(caseblock)
    coder:inc_indent() coder:add_indent_ln('break;') coder:dec_indent()
    coder:add_indent_ln("}")
  end
  if switchelseblock then
    coder:add_indent_ln('default: {')
    coder:add(switchelseblock)
    coder:inc_indent() coder:add_indent_ln('break;') coder:dec_indent()
    coder:add_indent_ln("}")
  end
  coder:dec_indent()
  coder:add_indent_ln("}")
end)

generator:register('Do', function(_, ast, coder)
  local block = ast:args()
  coder:add_indent_ln("{")
  coder:add(block)
  coder:add_indent_ln("}")
end)

generator:register('While', function(_, ast, coder)
  local cond, block = ast:args()
  coder:add_indent_ln("while(", cond, ') {')
  coder:add(block)
  coder:add_indent_ln("}")
end)

generator:register('Repeat', function(_, ast, coder)
  local block, cond = ast:args()
  coder:add_indent_ln("do {")
  coder:add(block)
  coder:add_indent_ln('} while(!(', cond, '));')
end)

generator:register('ForNum', function(_, ast, coder)
  local itvar, beginval, comp, endval, incrval, block  = ast:args()
  ast:assertf(comp == 'le', 'for comparator not supported yet')
  local itname = itvar[1]
  coder:add_indent("for(", itvar, ' = ', beginval, '; ', itname, ' <= ', endval, '; ')
  if incrval then
    coder:add(itname, ' += ', incrval)
  else
    coder:add('++', itname)
  end
  coder:add_ln(') {')
  coder:add(block)
  coder:add_indent_ln("}")
end)

-- TODO: ForIn

generator:register('Break', function(_, _, coder)
  coder:add_indent_ln('break;')
end)

generator:register('Continue', function(_, _, coder)
  coder:add_indent_ln('continue;')
end)

generator:register('Label', function(_, ast, coder)
  local name = ast:args()
  coder:add_indent_ln(name, ':')
end)

generator:register('Goto', function(_, ast, coder)
  local labelname = ast:args()
  coder:add_indent_ln('goto ', labelname, ';')
end)

generator:register('VarDecl', function(_, ast, coder)
  local varscope, mutability, vars, vals = ast:args()
  ast:assertf(mutability == 'var', 'variable mutability not supported yet')
  ast:assertf(varscope == 'local', 'global variables not supported yet')
  ast:assertf(not vals or #vars == #vals, 'vars and vals count differs')
  coder:add_indent()
  for i=1,#vars do
    local var, val = vars[i], vals and vals[i]
    if i > 1 then coder:add(' ') end
    coder:add(var)
    if val then
      coder:add(' = ', val)
    end
    coder:add(';')
  end
  coder:add_ln()
end)


generator:register('Assign', function(_, ast, coder)
  local vars, vals = ast:args()
  ast:assertf(#vars == #vals, 'vars and vals count differs')
  coder:add_indent()
  for i=1,#vars do
    local var, val = vars[i], vals[i]
    if i > 1 then coder:add(' ') end
    coder:add(var, ' = ', val, ';')
  end
  coder:add_ln()
end)

generator:register('FuncDef', function(context, ast)
  local varscope, name, args, rets, block = ast:args()
  ast:assertf(#rets <= 1, 'multiple returns not supported yet')
  ast:assertf(varscope == 'local', 'non local scope for functions not supported yet')
  local coder = context.declarations_coder
  if #rets == 0 then
    coder:add_indent('void ')
  else
    local ret = rets[1]
    ast:assertf(ret.tag == 'Type')
    coder:add_indent(ret, ' ')
  end
  coder:add_ln(name, '(', args, ') {')
  coder:add(block)
  coder:add_indent_ln('}')
end)

-- operators
local function is_in_operator(context)
  local parent_ast = context:get_parent_ast()
  if not parent_ast then return false end
  local parent_ast_tag = parent_ast.tag
  return
    parent_ast_tag == 'UnaryOp' or
    parent_ast_tag == 'BinaryOp' or
    parent_ast_tag == 'TernaryOp'
end

local C_UNARY_OPS = {
  ['not'] = '!',
  ['neg'] = '-',
  ['bnot'] = '~',
  ['ref'] = '&',
  ['deref'] = '*',
  --TODO: len
  --TODO: tostring
}
generator:register('UnaryOp', function(context, ast, coder)
  local opname, arg = ast:args()
  local op = ast:assertf(C_UNARY_OPS[opname], 'unary operator "%s" not found', opname)
  local surround = is_in_operator(context)
  if surround then coder:add('(') end
  coder:add(op, arg)
  if surround then coder:add(')') end
end)

local BINARY_OPS = {
  ['or'] = '||',
  ['and'] = '&&',
  ['ne'] = '!=',
  ['eq'] = '==',
  ['le'] = '<=',
  ['ge'] = '>=',
  ['lt'] = '<',
  ['gt'] = '>',
  ['bor'] = '|',
  ['bxor'] = '^',
  ['band'] = '&',
  ['shl'] = '<<',
  ['shr'] = '>>',
  ['add'] = '+',
  ['sub'] = '-',
  ['mul'] = '*',
  ['div'] = '/',
  ['mod'] = '%',
  --TODO: idiv
  --TODO: pow
  --TODO: concat
}
generator:register('BinaryOp', function(context, ast, coder)
  local opname, left_arg, right_arg = ast:args()
  local op = ast:assertf(BINARY_OPS[opname], 'binary operator "%s" not found', opname)
  local surround = is_in_operator(context)
  if surround then coder:add('(') end
  coder:add(left_arg, ' ', op, ' ', right_arg)
  if surround then coder:add(')') end
end)

generator:register('TernaryOp', function(context, ast, coder)
  local opname, left_arg, mid_arg, right_arg = ast:args()
  ast:assertf(opname == 'if', 'unknown ternary operator "%s"', opname)
  local surround = is_in_operator(context)
  if surround then coder:add('(') end
  coder:add(mid_arg, ' ? ', left_arg, ' : ', right_arg)
  if surround then coder:add(')') end
end)

function generator:generate(ast)
  local context = self:newContext()
  local indent = '    '

  context.includes_coder = Coder(context, indent, 0)
  context.builtins_declarations_coder = Coder(context, indent, 0)
  context.builtins_definitions_coder = Coder(context, indent, 0)
  context.declarations_coder = Coder(context, indent, 0)
  context.definitions_coder = Coder(context, indent, 0)
  context.main_coder = Coder(context, indent)

  context.main_coder:add_traversal(ast)

  local code = table.concat({
    context.includes_coder:generate(),
    context.builtins_declarations_coder:generate(),
    context.builtins_definitions_coder:generate(),
    context.declarations_coder:generate(),
    context.definitions_coder:generate(),
    context.main_coder:generate()
  })

  return code
end

generator.compiler = require('euluna.compilers.c_compiler')

return generator
