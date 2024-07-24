struct FormatSkip
    startline::Int
    endline::Int
    startoffset::Int
    endoffset::Int
end

struct Document
    srcfile::JuliaSyntax.SourceFile
    format_skips::Vector{FormatSkip}
    # Line where there's a noindent comment. "#! format: noindent". This is checked during
    # the print stage to know if the contents of the block (recursive) should not be indented.
    noindent_blocks::Vector{Int}

    lit_strings::Dict{Int,Tuple{Int,Int,String}}
    comments::Dict{Int,Tuple{Int,String}}
    semicolons::Dict{Int,Vector{Int}}

    ends_on_nl::Bool
end

function Document(text::AbstractString)
    format_skips = FormatSkip[]
    noindent_blocks = Int[]
    stack = Tuple{Int,Int}[]
    comments = Dict{Int,Tuple{Int,String}}()
    semicolons = Dict{Int,Vector{Int}}()
    lit_strings = Dict{Int,Tuple{Int,Int,String}}()

    srcfile = JuliaSyntax.SourceFile(text)
    tokens = JuliaSyntax.tokenize(text)
    string_stack = Tuple{Int,Int,String}[]

    ends_on_nl = tokens[end].head.kind === K"NewlineWs"

    for (i, t) in enumerate(tokens)
        kind = t.head.kind

        if kind in (K"\"\"\"", K"```", K"\"", K"`")
            if isempty(string_stack)
                # Opening quote
                start_offset = first(t.range)
                start_line = JuliaSyntax.source_line(srcfile, first(t.range))
                opening_quote = if kind === K"\"\"\""
                    "\"\"\""
                elseif kind === K"```"
                    "```"
                elseif kind === K"\""
                    "\""
                elseif kind === K"`"
                    "`"
                end
                push!(string_stack, (start_offset, start_line, opening_quote))
            else
                # Closing quote
                start_offset, start_line, opening_quote = pop!(string_stack)
                end_offset = last(t.range)
                end_line = JuliaSyntax.source_line(srcfile, last(t.range))

                # Capture the full string content
                full_string = text[start_offset+1:end_offset]

                lit_strings[start_offset] = (start_line, end_line, full_string)
            end
        elseif !isempty(string_stack)
            # We're inside a string, continue to next token
            continue
        elseif kind === K"Comment"
            ws = 0
            if i > 1 && (
                tokens[i-1].head.kind === K"Whitespace" ||
                tokens[i-1].head.kind === K"NewlineWs"
            )
                pt = tokens[i-1]
                prevval = try
                    srcfile.code[first(pt.range):last(pt.range)]
                catch e
                    if isa(e, StringIndexError)
                        srcfile.code[first(pt.range):prevind(srcfile.code, last(pt.range))]
                    else
                        rethrow(e)
                    end
                end

                idx = findlast(c -> c == '\n', prevval)
                idx === nothing && (idx = 1)
                ws = count(c -> c == ' ', prevval[idx:end])
            end

            startline = JuliaSyntax.source_line(srcfile, first(t.range))
            endline = JuliaSyntax.source_line(srcfile, last(t.range))
            val = try
                srcfile.code[first(t.range):last(t.range)]
            catch e
                if isa(e, StringIndexError)
                    srcfile.code[first(t.range):prevind(srcfile.code, last(t.range))]
                else
                    rethrow(e)
                end
            end

            if startline == endline
                if ws > 0
                    comments[startline] = (ws, val)
                else
                    comments[startline] = (ws, val)
                end
            else
                # multiline comment
                idx = findfirst(x -> x == '\n', val) + 1
                fc2 = findfirst(c -> !isspace(c), val[idx:end])

                lr = JuliaSyntax.source_line_range(srcfile, first(t.range))
                lineoffset = (first(t.range) - lr[1]) + 1
                ws2 = fc2 === nothing || lineoffset < fc2 ? ws : max(ws, fc2 - 1)

                line = startline
                cs = ""
                for (i, c) in enumerate(val)
                    cs *= c
                    if c == '\n'
                        fc = findfirst(c -> !isspace(c), cs)
                        if fc === nothing
                            # comment is all whitespace
                            comments[line] = (ws, cs[end:end])
                        else
                            idx = min(fc, ws + 1)
                            comments[line] = (ws, cs[idx:end])
                        end
                        line += 1
                        ws = ws2
                        cs = ""
                    end
                end
                # last comment
                idx = min(findfirst(c -> !isspace(c), cs)::Int, ws + 1)
                comments[line] = (ws, cs[idx:end])
            end

            if length(stack) == 0 && occursin(r"^#!\s*format\s*:\s*off\s*$", val)
                # There should not be more than 1
                # "off" tag on the stack at a time.
                offset = first(t.range)
                r = JuliaSyntax.source_line_range(srcfile, offset)
                line = JuliaSyntax.source_line(srcfile, offset)
                push!(stack, (line, first(r)))
            elseif length(stack) > 0 && occursin(r"^#!\s*format\s*:\s*on\s*$", val)
                # If "#! format: off" has not been seen
                # "#! format: on" is treated as a normal comment.
                offset = last(t.range)
                r = JuliaSyntax.source_line_range(srcfile, offset)
                line = JuliaSyntax.source_line(srcfile, offset)
                v = pop!(stack)
                push!(format_skips, FormatSkip(v[1], line, v[2], last(r)))
            end
            if occursin(r"^#!\s*format\s*:\s*noindent\s*$", val)
                line = JuliaSyntax.source_line(srcfile, first(t.range))
                push!(noindent_blocks, line)
            end
        elseif kind === K"ErrorEofMultiComment"
            l = JuliaSyntax.source_line(srcfile, first(t.range))
            throw(
                ErrorException(
                    """Unable to format. Multi-line comment on line $l is not closed.""",
                ),
            )
        elseif kind === K";"
            line = JuliaSyntax.source_line(srcfile, first(t.range))
            if haskey(semicolons, line)
                if i > 1 && tokens[i-1].head.kind === K";"
                    semicolons[line][end] += 1
                else
                    push!(semicolons[line], 1)
                end
            else
                semicolons[line] = Int[1]
            end
        end
    end

    # If there is a SINGLE "#! format: off" tag
    # do not format from the "off" tag onwards.
    if length(stack) == 1 && length(format_skips) == 0
        # -1 signifies everything afterwards "#! format: off"
        # will not formatted.
        v = pop!(stack)
        line = numlines(srcfile)
        r = JuliaSyntax.source_line_range(srcfile, srcfile.line_starts[line])
        push!(format_skips, FormatSkip(v[1], line, v[2], last(r)))
    end

    return Document(
        srcfile,
        format_skips,
        noindent_blocks,
        lit_strings,
        comments,
        semicolons,
        ends_on_nl,
    )
end

function has_noindent_block(d::Document, r::Tuple{Int,Int})
    for b in d.noindent_blocks
        b in r && return true
    end
    return false
end

numlines(sf::JuliaSyntax.SourceFile) = length(sf.line_starts) - 1
numlines(d::Document) = numlines(d.srcfile)


function getsrcval(d::Document, r::UnitRange{Int})
    try
        d.srcfile.code[r]
    catch
        d.srcfile.code[r[1]:prevind(d.srcfile.code, r[2])]
    end
end
