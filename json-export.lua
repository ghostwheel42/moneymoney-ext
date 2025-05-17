-- Copyright (c) 2022-2025 Alexander Graf

Exporter {
  version       = 1.00,
  format        = 'JSON',
  fileExtension = 'json',
  description   = 'Export transactions as JSON file'
}

-- dump lua table
local format
local function dumpTable(arg)
  local res   = {}
  local keys  = {}
  local write = {}
  local fn, fm
  for k, v in pairs(arg.table) do
    fn = format[k]
    if type(fn) ~= 'function' then
      fn = format[type(v)]
    end
    if type(fn) == 'function' then
      fm = fn(v, arg.indent)
      if fm ~= nil then
        keys[#keys + 1] = k
        write[k] = string.format('%s%q: %s', arg.indent, k, fm)
      end
    end
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    res[#res + 1] = write[k]
  end
  return table.concat(res, ',\n')
end

-- format functions
local function format_quote(v, i)
  if v == '' then
    return nil
  else
    return string.format('%q', v)
  end
end

local function format_string(v, i)
  return string.format('%s', v)
end

local function format_date(v, i)
  return string.format('%q', os.date('!%Y-%m-%dT%T', v))
end

local function format_skip(v, i)
  return nil
end

local function format_table(v, i)
  if type(next(v)) ~= 'nil' then
    return string.format('{\n%s\n%s}', dumpTable { table = v, indent = i .. '  ' }, i)
  else
    return nil
  end
end

-- format specs
format = {
  -- fmt by type
  ['boolean']     = format_string,
  ['number']      = format_string,
  ['string']      = format_quote,
  ['table']       = format_table,
  -- fmt by key
  ['balanceDate'] = format_date,
  ['bookingDate'] = format_date,
  ['valueDate']   = format_date,
  ['id']          = format_skip,
}

-- export
local first
function WriteHeader(account, startDate, endDate, transactionCount)
  assert(io.write(string.format([[{
  "comment": "%s: %s - %s (%d transactions)",
  "account": %s,
  "transactions": [
]],
    account.name,
    MM.localizeDate(startDate), MM.localizeDate(endDate),
    transactionCount, format_table(account, '  ')
  )))
  first = true
end

function WriteTransactions(account, transactions)
  for _, transaction in ipairs(transactions) do
    if first then
      first = false
    else
      assert(io.write(',\n'))
    end
    assert(io.write('    ', format_table(transaction, '    ')))
  end
end

function WriteTail(account)
  assert(io.write('\n  ]\n}\n'))
end
