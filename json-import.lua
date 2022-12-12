Importer {
  version       = 1.00,
  format        = 'JSON',
  fileExtension = 'json',
  description   = 'Import transactions from JSON file'
}

-- TODO: better display of error location 'while parsing key ...'

-- json parser
-- (inspired by https://gist.github.com/tylerneylon/59f4bcf316be525b30ab)
local parse_json

local function skip(str, pos, expect, err_if_missing)
  -- skip whitespace
  pos = pos + #str:match('^[ \r\n\t]*', pos)
  -- get next character
  local nextc = str:sub(pos, pos)
  if nextc == nil then
    -- end of file?
    error({ msg = 'unexpected eof' })
  elseif expect == nil then
    -- only skip whitespace?
    return pos, nextc
  elseif nextc ~= expect then
    -- expected character?
    if err_if_missing then
      error({ msg = string.format('expected %q but found %q', expect, nextc), pos = pos })
    end
    -- not found
    return pos, false
  else
    -- found
    return pos + 1, true
  end
end

local function parse_object(str, pos)
  pos = pos + 1
  local obj, delim_found = {}, true
  local key
  while true do
    key, pos = parse_json(str, pos, '}')
    if key == nil then
      return obj, pos
    elseif not delim_found then
      error({ msg = 'comma missing between object items', pos = pos })
    else
      pos = skip(str, pos, ':', true)
      obj[key], pos = parse_json(str, pos)
      pos, delim_found = skip(str, pos, ',')
    end
  end
end

local function parse_array(str, pos)
  pos = pos + 1
  local arr, delim_found = {}, true
  local val
  while true do
    val, pos = parse_json(str, pos, ']')
    if val == nil then
      return arr, pos
    elseif not delim_found then
      error({ msg = 'comma missing between array items', pos = pos })
    else
      arr[#arr + 1] = val
      pos, delim_found = skip(str, pos, ',')
    end
  end
end

local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
local function parse_string(str, pos, val)
  pos = pos + 1
  val = val or ''
  -- match valid 1-byte codepoints 0x20 - 0x7f excluding " and \
  local part = str:match('^[] !#-\091\094-\127]+', pos)
  if part ~= nil then
    val = val .. part
    pos = pos + #part
  end
  -- get next character
  local nextc = str:sub(pos, pos)
  if nextc == nil then
    -- end of file?
    error({ msg = 'unexpected eof while parsing string' })
  elseif nextc == '"' then
    -- end of string
    return val, pos + 1
  elseif nextc == '\\' then
    -- backslash escape
    nextc = str:sub(pos + 1, pos + 1)
    if nextc == nil then
      -- end of file?
      error({ msg = 'unexpected eof while parsing backslash escape' })
    elseif nextc == 'u' then
      -- handle escaped codepoint \uxxxx
      local hex = str:sub(pos + 2, pos + 5)
      local h, l = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16)
      if h == nil or l == nil then
        error({ msg = 'invalid hex escape code in string', token = hex, pos = pos })
      else
        local c = MM.fromEncoding('UTF-32BE', '\0\0' .. string.char(h) .. string.char(l))
        return parse_string(str, pos + 5, val .. c)
      end
    else
      -- handle mapped escapes
      local mapped = escapes[nextc]
      if mapped == nil then
        -- invalid escape code
        error({ msg = 'invalid escape code in string', token = nextc, pos = pos })
      else
        return parse_string(str, pos + 1, val .. mapped)
      end
    end
  else
    -- unicode glyph or invalid codepoint
    local c, s = nextc:byte(), 3
    if c < 0x20 or c > 0xf7 then
      error({ msg = 'invalid codepoint in string', token = string.format('0x%02x', c), pos = pos })
    elseif c <= 0xdf then -- 0b110xxxxx: 2-byte glyph
      s = 1
    elseif c <= 0xef then -- 0b1110xxxx: 3-byte glyph
      s = 2
    end -- 0b11110xxx: 4-byte glyph
    -- check continuation bytes
    for i = 1, s do
      c = str:sub(pos + i, pos + i):byte()
      if c < 128 or c > 191 then -- 0b10xxxxxx
        error({
          msg = 'invalid utf-8 codepoint in string',
          token = str:sub(pos, pos + s):gsub('.', function(c) return string.format('%02x', c:byte()) end),
          pos = pos
        })
      end
    end
    return parse_string(str, pos + s, val .. str:sub(pos, pos + s))
  end
end

local function parse_number(str, pos)
  local num = str:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
  local val = tonumber(num)
  if val ~= nil then
    return val, pos + #num
  end
  error({ msg = 'invalid number', token = num, pos = pos })
end

local literals = { ['true'] = true, ['false'] = false, ['null'] = { nil } }
local function parse_literal(str, pos)
  for literal, value in pairs(literals) do
    if str:sub(pos, pos + #literal - 1) == literal then
      return value, pos + #literal
    end
  end
  error({ msg = 'invalid literal', token = str:match('^%S+', pos), pos = pos })
end

-- parser lookup table
local parsers = {
  ['{'] = parse_object,
  ['['] = parse_array,
  ['"'] = parse_string,
  ['-'] = parse_number,
}
for i = 0, 9 do parsers[tostring(i)] = parse_number end
for s, _ in pairs(literals) do parsers[s:sub(1, 1)] = parse_literal end

-- json parser
function parse_json(str, pos, stop)
  -- skip whitespace and get next character
  local nextc
  pos, nextc = skip(str, pos)
  -- end of an object or array?
  if nextc == stop then
    return nil, pos + 1
  end
  -- call parser
  local parser = parsers[nextc]
  if parser == nil then
    error({ msg = 'syntax error', pos = pos })
  end
  return parser(str, pos)
end

-- validation
local function validate_string(i, key, value)
  if type(value) == 'string' then
    return value
  end
  error(string.format('invalid value %q for key %q in transaction #%d', value, key, i))
end

local function validate_date(i, key, value)
  if type(value) == 'string' then
    local y, m, d, hh, mm, ss = value:match('^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)$')
    if y ~= nil then
      return os.time({ year = y, month = m, day = d, hour = hh, min = mm, sec = ss, isdst = false })
    end
  end
  error(string.format('invalid value %q for key %q in transaction #%d', value, key, i))
end

local function validate_int(i, key, value)
  --  if math.type(value) == 'integer' then
  if value == math.floor(value) then
    return value
  end
  error(string.format('invalid value %q for key %q in transaction #%d', value, key, i))
end

local function validate_float(i, key, value)
  if type(value) == 'number' then
    return value
  end
  error(string.format('invalid value %q for key %q in transaction #%d', value, key, i))
end

local function validate_bool(i, key, value)
  if value == true or value == false then
    return value
  end
  error(string.format('invalid value %q for key %q in transaction #%d', value, key, i))
end

local function validate_ignore(i, key, value)
  return nil
end

local validators = {
  ['name']              = validate_string,
  ['accountNumber']     = validate_string,
  ['bankCode']          = validate_string,
  ['amount']            = validate_float,
  ['currency']          = validate_string,
  ['bookingDate']       = validate_date,
  ['valueDate']         = validate_date,
  ['purpose']           = validate_string,
  ['transactionCode']   = validate_int,
  ['textKeyExtension']  = validate_int,
  ['purposeCode']       = validate_string,
  ['bookingKey']        = validate_string,
  ['bookingText']       = validate_string,
  ['primanotaNumber']   = validate_string,
  ['batchReference']    = validate_string,
  ['endToEndReference'] = validate_string,
  ['mandateReference']  = validate_string,
  ['creditorId']        = validate_string,
  ['returnReason']      = validate_string,
  ['booked']            = validate_bool,
  ['category']          = validate_string,
  ['comment']           = validate_string,
  ['type']              = validate_ignore,
  ['checkmark']         = validate_ignore,
}

-- import
function ReadTransactions(account)

  -- read file
  local data = assert(io.read("*all"))

  -- parse json
  local status, result = pcall(parse_json, data, 1)
  if not status then
    local err = 'Invalid JSON: ' .. (result.msg or result)
    if result.token then
      err = err .. string.format(' %q', result.token)
    end
    if result.pos then
      local line = select(2, string.gsub(data:sub(1, result.pos), '\n', '')) + 1
      err = err .. string.format(' at position #%d (line %d)', result.pos, line)
    end
    return err
  end

  -- validate transactions
  local trans = result['transactions']
  local ttype = type(trans)
  if ttype == nil then
    return 'JSON does not contain the key "transactions"'
  elseif ttype ~= 'table' or type(trans[1]) == nil then
    return 'The key "transactions" is not an array'
  end
  for i, transaction in ipairs(trans) do
    for k, v in pairs(transaction) do
      if validators[k] == nil then
        return string.format('invalid key %q in transaction #%d', k, i)
      end
      local checked
      status, checked = pcall(validators[k], i, k, v)
      if not status then
        return checked
      end
      -- delete key if nil
      if checked ~= nil then
        transaction[k] = checked
      end
    end
  end

  return trans

end
