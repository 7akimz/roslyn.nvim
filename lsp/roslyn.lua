local sysname = vim.uv.os_uname().sysname:lower()
local iswin = not not (sysname:find("windows") or sysname:find("mingw"))

local function get_mason_path()
    local expanded_mason = vim.fn.expand("$MASON")
    return expanded_mason == "$MASON" and vim.fs.joinpath(vim.fn.stdpath("data"), "mason") or expanded_mason
end

local function get_exe()
    local roslyn_bin = iswin and "roslyn.cmd" or "roslyn"
    local mason_bin = vim.fs.joinpath(get_mason_path(), "bin", roslyn_bin)

    return vim.fn.executable(mason_bin) == 1 and mason_bin
        or vim.fn.executable(roslyn_bin) == 1 and roslyn_bin
        or "Microsoft.CodeAnalysis.LanguageServer"
end

local function find_razor_extension_path()
    local mason_packages = vim.fs.joinpath(get_mason_path(), "packages")

    local stable_path = vim.fs.joinpath(mason_packages, "roslyn", "libexec", ".razorExtension")
    if vim.fn.isdirectory(stable_path) == 1 then
        return stable_path
    end

    -- TODO: Once the .razorExtension moves to the stable roslyn package, remove this
    local unstable_path = vim.fs.joinpath(mason_packages, "roslyn-unstable", "libexec", ".razorExtension")
    if vim.fn.isdirectory(unstable_path) == 1 then
        return unstable_path
    end

    return nil
end

local function get_base_args()
    local args = {
        "--logLevel=Information",
        "--extensionLogDirectory=" .. vim.fs.dirname(vim.lsp.log.get_filename()),
    }

    local razor_extension_path = find_razor_extension_path()
    if razor_extension_path ~= nil then
        vim.list_extend(args, {
            "--razorSourceGenerator="
                .. vim.fs.joinpath(razor_extension_path, "Microsoft.CodeAnalysis.Razor.Compiler.dll"),
            "--razorDesignTimePath="
                .. vim.fs.joinpath(razor_extension_path, "Targets", "Microsoft.NET.Sdk.Razor.DesignTime.targets"),
            "--extension",
            vim.fs.joinpath(razor_extension_path, "Microsoft.VisualStudioCode.RazorExtension.dll"),
        })
    end

    return args
end

local function get_cmd_env()
    return {
        Configuration = vim.env.Configuration or "Debug",
        TMPDIR = vim.env.TMPDIR and vim.fn.resolve(vim.env.TMPDIR) or nil,
    }
end

local function supports_stdio(exe)
    local output = vim.fn.system({ exe, "--help" })
    return output:find("%-%-stdio") ~= nil
end

local function get_default_cmd()
    local exe = get_exe()

    if supports_stdio(exe) then
        local cmd = { exe }
        vim.list_extend(cmd, get_base_args())
        table.insert(cmd, "--stdio")
        return cmd
    end

    return function(dispatchers)
        local pipe_name = iswin and ("\\\\.\\pipe\\roslyn-" .. vim.uv.getpid())
            or vim.fs.joinpath(vim.fn.tempname(), "roslyn.sock")

        if not iswin then
            vim.fn.mkdir(vim.fs.dirname(pipe_name), "p")
        end

        local cmd_args = { exe }
        vim.list_extend(cmd_args, get_base_args())
        vim.list_extend(cmd_args, { "--pipe", pipe_name })

        local env = get_cmd_env()
        local env_list = {}
        for k, v in pairs(env) do
            table.insert(env_list, k .. "=" .. v)
        end

        local handle
        handle = vim.system(cmd_args, {
            env = env_list,
        }, function()
            handle = nil
        end)

        local max_attempts = 50
        local attempt = 0
        while attempt < max_attempts do
            if vim.uv.fs_stat(pipe_name) then
                break
            end
            vim.uv.sleep(100)
            attempt = attempt + 1
        end

        if attempt == max_attempts then
            vim.schedule(function()
                vim.notify(
                    "Roslyn server did not create pipe within 5s: " .. pipe_name,
                    vim.log.levels.ERROR,
                    { title = "roslyn.nvim" }
                )
            end)
            if handle then
                handle:kill("sigterm")
            end
            return nil
        end

        local connect = vim.lsp.rpc.connect(pipe_name)
        local rpc_client = connect(dispatchers)

        local original_terminate = rpc_client.terminate
        rpc_client.terminate = function(...)
            original_terminate(...)
            if handle then
                handle:kill("sigterm")
                handle = nil
            end
            if not iswin then
                vim.fn.delete(pipe_name)
                vim.fn.delete(vim.fs.dirname(pipe_name), "d")
            end
        end

        return rpc_client
    end
end

---@type vim.lsp.Config
return {
    name = "roslyn",
    filetypes = { "cs", "razor" },
    cmd = get_default_cmd(),
    cmd_env = get_cmd_env(),
    capabilities = {
        textDocument = {
            diagnostic = {
                dynamicRegistration = true,
            },
        },
    },
    settings = {
        razor = {
            language_server = {
                cohosting_enabled = true,
            },
        },
    },
    root_dir = function(bufnr, on_dir)
        if require("roslyn.config").get().lock_target and vim.g.roslyn_nvim_selected_solution then
            local root_dir = vim.fs.dirname(vim.g.roslyn_nvim_selected_solution)
            on_dir(root_dir)
            return
        end

        local buf_name = vim.api.nvim_buf_get_name(bufnr)
        if buf_name:match("^roslyn%-source%-generated://") then
            local existing_client = vim.lsp.get_clients({ name = "roslyn" })[1]
            if existing_client and existing_client.config.root_dir then
                on_dir(existing_client.config.root_dir)
                return
            end
        end

        local root_dir = require("roslyn.sln.utils").root_dir(bufnr)
        on_dir(root_dir)
    end,
    on_init = {
        function(client)
            client.server_capabilities.renameProvider = true

            -- TODO: Remove when 0.12 is stable
            if vim.fn.has("nvim-0.12") == 0 then
                vim.api.nvim_create_autocmd("LspAttach", {
                    callback = function(args)
                        if vim.api.nvim_get_option_value("filetype", { buf = args.buf }) == "razor" then
                            if args.data.client_id == client.id then
                                client.server_capabilities.semanticTokensProvider.full = nil
                            end
                        end
                    end,
                })
            end

            if not client.config.root_dir then
                return
            end
            require("roslyn.log").log(string.format("lsp on_init root_dir: %s", client.config.root_dir))

            local utils = require("roslyn.sln.utils")
            local on_init = require("roslyn.lsp.on_init")

            local config = require("roslyn.config").get()
            local selected_solution = vim.g.roslyn_nvim_selected_solution
            if config.lock_target and selected_solution then
                return on_init.sln(client, selected_solution)
            end

            local files = utils.find_files_with_extensions(client.config.root_dir, { ".sln", ".slnx", ".slnf" })

            local bufnr = vim.api.nvim_get_current_buf()
            local solution = utils.predict_target(bufnr, files)
            if solution then
                return on_init.sln(client, solution)
            end

            local csproj = utils.find_files_with_extensions(client.config.root_dir, { ".csproj" })
            if #csproj > 0 then
                return on_init.project(client, csproj)
            end

            if selected_solution then
                return on_init.sln(client, selected_solution)
            end
        end,
    },
    on_exit = {
        function(_, _, client_id)
            require("roslyn.store").set(client_id, nil)
            vim.schedule(function()
                require("roslyn.roslyn_emitter").emit("stopped")
                vim.notify("Roslyn server stopped", vim.log.levels.INFO, { title = "roslyn.nvim" })
            end)
        end,
    },
    commands = require("roslyn.lsp.commands"),
    handlers = require("roslyn.lsp.handlers"),
}
