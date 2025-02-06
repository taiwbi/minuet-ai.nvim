local utils = require 'minuet.utils'
local common = require 'minuet.backends.common'
local Job = require 'plenary.job'

local M = {}

M.is_available = function()
    local config = require('minuet').config
    return utils.get_api_key(config.provider_options.claude.api_key) and true or false
end

if not M.is_available() then
    utils.notify('Anthropic API key is not set', 'error', vim.log.levels.ERROR)
end

local function make_request_data()
    local config = require('minuet').config
    local options = vim.deepcopy(config.provider_options.claude)
    local system = utils.make_system_prompt(options.system, config.n_completions)

    local request_data = {
        system = system,
        max_tokens = options.max_tokens,
        model = options.model,
        stream = options.stream,
    }

    request_data = vim.tbl_deep_extend('force', request_data, options.optional or {})

    return options, request_data
end

function M.get_text_fn_no_steam(json)
    return json.content[1].text
end

function M.get_text_fn_stream(json)
    return json.delta.text
end

M.complete = function(context, callback)
    local config = require('minuet').config

    common.terminate_all_jobs()

    local options, data = make_request_data()
    local ctx = utils.make_chat_llm_shot(context, options.chat_input)

    local few_shots = vim.deepcopy(utils.get_or_eval_value(options.few_shots))

    table.insert(few_shots, { role = 'user', content = ctx })

    data.messages = few_shots

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        return
    end

    local args = {
        'https://api.anthropic.com/v1/messages',
        '-H',
        'Content-Type: application/json',
        '-H',
        'x-api-key: ' .. utils.get_api_key(options.api_key),
        '-H',
        'anthropic-version: 2023-06-01',
        '--max-time',
        tostring(config.request_timeout),
        '-d',
        '@' .. data_file,
    }

    if config.proxy then
        table.insert(args, '--proxy')
        table.insert(args, config.proxy)
    end

    local new_job = Job:new {
        command = 'curl',
        args = args,
        on_exit = vim.schedule_wrap(function(job, exit_code)
            common.remove_job(job)

            local items_raw

            if options.stream then
                items_raw = utils.stream_decode(job, exit_code, data_file, 'Claude', M.get_text_fn_stream)
            else
                items_raw = utils.no_stream_decode(job, exit_code, data_file, 'Claude', M.get_text_fn_no_steam)
            end

            if not items_raw then
                callback()
                return
            end

            local items = common.parse_completion_items(items_raw, 'Claude')

            items = common.filter_context_sequences_in_items(items, context.lines_after)

            items = utils.remove_spaces(items)

            callback(items)
        end),
    }

    common.register_job(new_job)
    new_job:start()
end

return M
