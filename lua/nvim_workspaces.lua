-- main module file
local module = require("nvim_workspaces.module")

---@class MyModule
local M = {}

M.file_map = {}
M.opts = {}
M.tmpfile = nil

M.setup = function(args)
   M.config = vim.tbl_deep_extend("force", M.config, args or {})
end

M.openFile = function (opts)
   local name = string.gsub(opts.args, "%s+", "")
   if(M.file_map[name] == nil) then
      print("Could not find '" .. name .. "'")
      return
   end
   vim.cmd('drop ' .. M.file_map[name])
end

M.completeFileName = function(ArgLead, CmdLine, CursorPos) 
   local ret = {}
   for key, val in pairs(M.file_map) do
      if(string.sub(key,1,string.len(ArgLead))==ArgLead) then
         table.insert(ret, key)
      end
   end
   return ret
end

string.startswith = function(self, str) 
    return self:find('^' .. str) ~= nil
end

string.parselist = function(self) 
   local list = self:match("=(.*)")
   local i = 1
   local ret = {}
   for entry in list:gmatch('([^,]+)') do 
      ret[i] = entry
      i = i + 1
   end
   return ret
end

local function parseconfig() 
   if(vim.uv.fs_stat("workspace.config")) then
      for line in io.lines("workspace.config") do
         if line:startswith("excludedDirs") then
            M.opts.excludedDirs = line:parselist()
         end

         if line:startswith("extraDirs") then
            local dirs = line:parselist()
            for _, dir in ipairs(dirs) do
               table.insert(M.opts.dirs, vim.fn.resolve(vim.fn.expand(dir)))
            end
         end

         if line:startswith("extensions") then
            M.opts.extensions = line:parselist()
         end
      end
   end
end

local function create_lookup(extensions)
   local lookup = {}
   for _, ext in ipairs(extensions or {}) do
      lookup[ext:lower()] = true
   end
   return lookup
end

local function updateTempFile()
   if not M.tmpfile then
      return
   end
   
   local f = io.open(M.tmpfile, "w")
   if not f then
      print("Failed to update temp file")
      return
   end

   for _, file in pairs(M.file_map) do
      f:write(file .. "\n")
   end
   f:close()
end

local function findFiles(dirs, extensions, exclude)
   local seen = {}
   local ext_lookup = create_lookup(extensions)

   local function should_include(name)
      if not exclude then
         return true
      end
      for _, excluded in ipairs(exclude) do
         if name == excluded then
            return false
         end
      end
      return true
   end

   local queue = {}
   for _, dir in ipairs(dirs) do
      if not seen[dir] then
         seen[dir] = true
         table.insert(queue, dir)
      end
   end

   local running_threads = 0

   local function process() 
      if #queue == 0 and running_threads == 0 then
         vim.schedule(function()
            print("Scan complete! Found " .. vim.tbl_count(M.file_map) .. " files")
            updateTempFile()
         end)
         return
      end

      if #queue == 0 then
         return
      end

      local current_dir = table.remove(queue, 1)
      running_threads = running_threads + 1

      local handle, err = vim.loop.fs_scandir(current_dir)
      if err or not handle then
         vim.schedule(function()
            print("Error scanning " .. current_dir .. ": " .. (err or "unknown"))
         end)
         running_threads = running_threads - 1
         process()
         return
      end

      local function iterate()
         local name, type = vim.loop.fs_scandir_next(handle)
         
         if not name then 
            running_threads = running_threads - 1
            process()
            return
         end

         local path = vim.fs.joinpath(current_dir, name)

         if type == 'directory' then
            if should_include(name) and not seen[path] then
               seen[path] = true
               table.insert(queue, path)
            end

         elseif type == 'file' then
            if not M.file_map[name] then
               local ext = vim.fn.fnamemodify(name, ":e")
               if ext ~= "" and ext_lookup[ext:lower()] then
                  M.file_map[name] = path
               end
            end
         end

         vim.schedule(iterate)
      end
      
      iterate()
   end

   for _ = 1, math.min(4, #queue) do
      process()
   end
end

M.initProject = function()
   M.file_map = {}
   M.opts = {}
   M.opts.dirs = {}
   M.opts.excludedDirs = {}
   M.opts.extensions = {}

   table.insert(M.opts.dirs, vim.uv.cwd())
   
   parseconfig()

   if M.tmpfile then
      vim.fn.delete(M.tmpfile)
   end
   M.tmpfile = vim.fn.tempname()

   findFiles(M.opts.dirs, M.opts.extensions, M.opts.excludedDirs)
end




M.grepWordUnderCursor = function()
   local has_telescope = pcall(require, "telescope")
   if not has_telescope then
      print("Telescope is not installed")
      return
   end

   if vim.fn.executable('rg') == 0 then
      print("ripgrep (rg) is not installed")
      return
   end

   if not M.tmpfile or vim.fn.filereadable(M.tmpfile) == 0 then
      print("Workspace not initialized. Run :WorkspaceInit first")
      return
   end

   local word = vim.fn.expand("<cword>")
   if word == "" then
      print("No word under cursor")
      return
   end

   local pickers = require("telescope.pickers")
   local finders = require("telescope.finders")
   local conf = require("telescope.config").values
   local make_entry = require("telescope.make_entry")
   local actions = require("telescope.actions")

   pickers.new({}, {
      prompt_title = "Live Grep (Workspace Files)",
      finder = finders.new_async_job({
         command_generator = function(prompt)
            if not prompt or prompt == "" then
               return nil
            end

            local cmd = {
               "rg",
               "--color=never",
               "--no-heading",
               "--with-filename",
               "--line-number",
               "--column",
               "--smart-case",
               prompt,
               "--",
            }
            
            for _, file in ipairs(files) do
               table.insert(cmd, file)
            end
            
            return cmd
         end,
         entry_maker = make_entry.gen_from_vimgrep({}),
         cwd = vim.fn.getcwd(),
      }),
      default_text = word,
      previewer = conf.grep_previewer({}),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
         actions.select_default:replace(function()
            actions.close(prompt_bufnr)
            local entry = require("telescope.actions.state").get_selected_entry()
            if entry then
               vim.cmd(string.format("edit +%d %s", entry.lnum, entry.filename))
            end
         end)
         return true
      end,
   }):find()
end

M.grepWorkspace = function(opts)
   opts = opts or {}
   
   local has_telescope = pcall(require, "telescope")
   if not has_telescope then
      print("Telescope is not installed")
      return
   end

   if vim.fn.executable('rg') == 0 then
      print("ripgrep (rg) is not installed")
      return
   end

   if not M.tmpfile or vim.fn.filereadable(M.tmpfile) == 0 then
      print("Workspace not initialized. Run :WorkspaceInit first")
      return
   end

   local default_text = opts.default_text
   if not default_text and opts.use_word_under_cursor ~= false then
      default_text = vim.fn.expand("<cword>")
   end

   local pickers = require("telescope.pickers")
   local finders = require("telescope.finders")
   local conf = require("telescope.config").values
   local make_entry = require("telescope.make_entry")
   local actions = require("telescope.actions")

   pickers.new(opts, {
      prompt_title = "Live Grep (Workspace Files)",
      finder = finders.new_async_job({
         command_generator = function(prompt)
            if not prompt or prompt == "" then
               return nil
            end

            local cmd = {
               "rg",
               "--color=never",
               "--no-heading",
               "--with-filename",
               "--line-number",
               "--column",
               "--smart-case",
               prompt,
               "--",
            }
            
            for _, file in ipairs(files) do
               table.insert(cmd, file)
            end
            
            return cmd
         end,
         entry_maker = make_entry.gen_from_vimgrep(opts),
         cwd = vim.fn.getcwd(),
      }),
      default_text = default_text,
      previewer = conf.grep_previewer(opts),
      sorter = conf.generic_sorter(opts),
   }):find()
end

M.refreshTempFile = function()
   updateTempFile()
   print("Temp file refreshed with " .. vim.tbl_count(M.file_map) .. " files")
end

M.cleanup = function()
   if M.tmpfile then
      vim.fn.delete(M.tmpfile)
      M.tmpfile = nil
   end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
   callback = function()
      require('nvim_workspaces').cleanup()
   end,
})

return M