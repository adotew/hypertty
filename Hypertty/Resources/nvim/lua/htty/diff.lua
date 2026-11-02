-- :HttyDiff [path], a project diff like Zed's on the files' own buffers, so LSP
-- and :w just work. Changes since HEAD are highlighted in place, deleted lines
-- shown as virtual lines, unchanged regions folded, and every hunk is in the
-- quickfix list. `do` reverts the hunk under the cursor, ]f and [f go to the
-- next or previous changed file.
local M = {}

local ns = vim.api.nvim_create_namespace('htty_diff')
-- Unchanged lines kept around each change.
local context = 3
-- The changed files in `git status` order, and their HEAD text by path.
local files, originals = {}, {}
-- By buffer: { original, groups, tick, hunks, near, rendered }.
local state = {}

local function git(args, cwd)
  local result = vim.system({ 'git', unpack(args) }, { cwd = cwd }):wait()
  return result.code == 0 and result.stdout or nil
end

-- { start_a, count_a, start_b, count_b } per hunk, 1-based; a count of 0 means
-- the change goes after line start.
local function hunks_of(original, lines)
  return vim.text.diff(original, table.concat(lines, '\n') .. '\n', { result_type = 'indices', algorithm = 'histogram' })
end

-- Treesitter highlight groups of `text` by line, then by byte, as the buffer's
-- own highlighting would color it. Empty without a parser for `filetype`.
local function highlights(text, filetype)
  local groups = {}
  local lang = vim.treesitter.language.get_lang(filetype)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  local query = ok and lang and vim.treesitter.query.get(lang, 'highlights')
  if not query then return groups end
  local lines = vim.split(text, '\n')
  -- shortcut: injected languages (code in Markdown, ...) stay plain; parse them too if that matters.
  for id, node in query:iter_captures(parser:parse()[1]:root(), text) do
    local name = query.captures[id]
    -- Private captures and those that only mark spelling or concealing aren't colors.
    if not (name:find('^_') or name == 'spell' or name == 'nospell' or name == 'conceal') then
      local start_row, start_col, end_row, end_col = node:range()
      for row = start_row, end_row do
        local line = groups[row + 1] or {}
        groups[row + 1] = line
        -- Later captures are the more specific ones.
        for col = row == start_row and start_col or 0, (row == end_row and end_col or #lines[row + 1]) - 1 do
          line[col + 1] = '@' .. name .. '.' .. lang
        end
      end
    end
  end
  return groups
end

-- A deleted line as virtual text chunks: its syntax colors over DiffDelete.
local function deleted_line(text, groups, tab, pad)
  local chunks = {}
  local start = 1
  for col = 1, #text do
    if groups[col + 1] ~= groups[col] or col == #text then
      local group = groups[start]
      chunks[#chunks + 1] = { text:sub(start, col):gsub('\t', tab), group and { 'DiffDelete', group } or 'DiffDelete' }
      start = col + 1
    end
  end
  chunks[#chunks + 1] = { pad, 'DiffDelete' }
  return chunks
end

local function compute(buf)
  local s = state[buf]
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if s.tick ~= tick then
    s.tick = tick
    s.hunks = hunks_of(s.original, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    s.near = {}
    for _, h in ipairs(s.hunks) do
      for line = h[3] - context, h[3] + math.max(h[4], 1) - 1 + context do
        s.near[line] = true
      end
    end
  end
  return s
end

local function render(buf)
  local s = compute(buf)
  if s.rendered == s.tick then return end
  s.rendered = s.tick
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local original = vim.split(s.original, '\n')
  -- Fills the rest of the line with the highlight.
  local pad = string.rep(' ', vim.o.columns)
  local tab = string.rep(' ', vim.bo[buf].tabstop)
  for _, h in ipairs(s.hunks) do
    local a, a_count, b, b_count = unpack(h)
    for row = b - 1, b + b_count - 2 do
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = 'DiffAdd' })
    end
    if a_count > 0 then
      local lines = {}
      for i = a, a + a_count - 1 do
        lines[#lines + 1] = deleted_line(original[i], s.groups[i] or {}, tab, pad)
      end
      -- Above the lines that replaced them, else below the line they followed.
      vim.api.nvim_buf_set_extmark(buf, ns, math.max(b - 1, 0), 0, {
        virt_lines = lines,
        virt_lines_above = b_count > 0 or b == 0,
      })
    end
  end
end

function M.foldexpr()
  local buf = vim.api.nvim_get_current_buf()
  if not state[buf] then return 0 end
  return compute(buf).near[vim.v.lnum] and 0 or 1
end

function M.foldtext()
  return ('  ▸ %d unchanged lines'):format(vim.v.foldend - vim.v.foldstart + 1)
end

-- Folds as a quiet band: comment-colored text on the cursor line's background.
local function define_highlights()
  local comment = vim.api.nvim_get_hl(0, { name = 'Comment', link = false })
  local cursorline = vim.api.nvim_get_hl(0, { name = 'CursorLine', link = false })
  vim.api.nvim_set_hl(0, 'HttyDiffFold', { fg = comment.fg, bg = cursorline.bg, default = true })
end
define_highlights()
vim.api.nvim_create_autocmd('ColorScheme', { callback = define_highlights })

-- The hunk under the cursor, back to its HEAD version.
local function revert(buf)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for _, h in ipairs(compute(buf).hunks) do
    local a, a_count, b, b_count = unpack(h)
    local first = b_count > 0 and b or math.max(b, 1)
    if line >= first and line <= first + math.max(b_count, 1) - 1 then
      local original = vim.list_slice(vim.split(state[buf].original, '\n'), a, a + a_count - 1)
      local start = b_count > 0 and b - 1 or b
      vim.api.nvim_buf_set_lines(buf, start, start + b_count, false, original)
      return
    end
  end
end

local function go_file(buf, step)
  local index = vim.iter(ipairs(files)):find(function(_, path) return path == vim.api.nvim_buf_get_name(buf) end)
  local path = index and files[index + step]
  if not path then return end
  vim.cmd.edit(vim.fn.fnameescape(path))
  local hunk = compute(vim.api.nvim_get_current_buf()).hunks[1]
  if hunk then vim.api.nvim_win_set_cursor(0, { math.max(hunk[3], 1), 0 }) end
end

local function attach(buf)
  if not state[buf] then
    local original = originals[vim.api.nvim_buf_get_name(buf)]
    state[buf] = { original = original, groups = highlights(original, vim.filetype.match({ buf = buf }) or '') }
    local group = vim.api.nvim_create_augroup('htty_diff_' .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
      group = group,
      buffer = buf,
      callback = function() render(buf) end,
    })
    local function map(lhs, rhs, desc) vim.keymap.set('n', lhs, rhs, { buffer = buf, desc = desc }) end
    map('do', function() revert(buf) end, 'Revert hunk')
    map(']f', function() go_file(buf, 1) end, 'Next changed file')
    map('[f', function() go_file(buf, -1) end, 'Previous changed file')
  end
  -- Treesitter for any language with a parser, like the deleted lines, even if the
  -- user's config only starts it for some. Again after a reload, which stops it.
  if not vim.treesitter.highlighter.active[buf] then pcall(vim.treesitter.start, buf) end
  render(buf)
  vim.opt_local.foldmethod = 'expr'
  vim.opt_local.foldexpr = "v:lua.require'htty.diff'.foldexpr()"
  vim.opt_local.foldtext = "v:lua.require'htty.diff'.foldtext()"
  vim.opt_local.fillchars:append({ fold = ' ' })
  vim.opt_local.winhighlight:append({ Folded = 'HttyDiffFold' })
  vim.opt_local.foldlevel = 0
  vim.opt_local.foldenable = true
end

function M.open(path)
  path = vim.fn.fnamemodify(path ~= '' and path or '.', ':p'):gsub('/$', '')
  local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
  local root = git({ 'rev-parse', '--show-toplevel' }, dir)
  if not root then return vim.notify('HttyDiff: ' .. path .. ' is not in a git work tree', vim.log.levels.ERROR) end
  root = vim.trim(root)

  -- Paths are relative to the root; renames and copies are followed by the old path.
  local status = git({ 'status', '--porcelain', '-z', '--untracked-files=all', '--', path }, root) or ''
  local entries = vim.split(status, '\0', { trimempty = true })
  files, originals = {}, {}
  local items = {}
  local i = 1
  while i <= #entries do
    local code, relative = entries[i]:sub(1, 2), entries[i]:sub(4)
    local head = relative
    if code:find('[RC]') then
      i = i + 1
      head = entries[i]
    end
    i = i + 1
    local full = root .. '/' .. relative
    local file = not code:find('D') and io.open(full, 'rb')
    if file then
      local text = file:read('*a')
      file:close()
      local original = code == '??' and '' or git({ 'show', 'HEAD:' .. head }, root) or ''
      -- Binary files are left out.
      if not (text:find('\0', 1, true) or original:find('\0', 1, true)) then
        local lines = vim.split(text, '\n')
        if lines[#lines] == '' then lines[#lines] = nil end
        local hunks = hunks_of(original, lines)
        if #hunks > 0 then
          files[#files + 1] = full
          originals[full] = original
          for _, h in ipairs(hunks) do
            local line = math.max(h[3], 1)
            local summary = h[4] > 0 and lines[line] or ('%d lines removed'):format(h[2])
            items[#items + 1] = { filename = full, lnum = line, text = vim.trim(summary) }
          end
        end
      end
    end
  end

  -- Buffers from an earlier :HttyDiff start over.
  for _, buf in ipairs(vim.tbl_keys(state)) do
    state[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      if originals[vim.api.nvim_buf_get_name(buf)] then
        attach(buf)
      else
        pcall(vim.keymap.del, 'n', 'do', { buffer = buf })
        pcall(vim.keymap.del, 'n', ']f', { buffer = buf })
        pcall(vim.keymap.del, 'n', '[f', { buffer = buf })
        vim.api.nvim_del_augroup_by_name('htty_diff_' .. buf)
      end
    end
  end
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = vim.api.nvim_create_augroup('htty_diff', { clear = true }),
    callback = function(args)
      if originals[vim.api.nvim_buf_get_name(args.buf)] then attach(args.buf) end
    end,
  })

  if #items == 0 then return vim.notify('HttyDiff: no changes in ' .. path) end
  vim.fn.setqflist({}, ' ', { title = 'Hypertty diff', items = items })
  vim.cmd.cfirst()
end

return M
