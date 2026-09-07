-- miniHawk Level B witness: play a project to its end and dump the final RAM.
--
-- Input comes from the movie, not from this script: the movie session drives the
-- controller chain exactly as it does for a user pressing Play. Nothing here runs
-- per frame except the frame advance itself.
--
-- Job description is read from the file named by the MINIHAWK_JOB env var:
--   out=<path to write the final RAM dump (binary)>
--   meta=<path to write result metadata (text)>

local function writeAll(path, data)
	local f = assert(io.open(path, "wb"))
	f:write(data)
	f:close()
end

local meta = {}
local function finish(status, detail)
	local lines = {
		"status=" .. status,
		"detail=" .. (detail or ""),
		"frames=" .. (meta.frames or 0),
		"lag=" .. (meta.lag or 0),
		"movieframes=" .. (meta.movieframes or 0),
	}
	if meta.metaPath then
		writeAll(meta.metaPath, table.concat(lines, "\n") .. "\n")
	end
	client.exit()
end

local jobPath = os.getenv("MINIHAWK_JOB")
if jobPath == nil then
	error("MINIHAWK_JOB env var not set")
end
local job = {}
for line in io.lines(jobPath) do
	local k, v = line:match("^([^=]+)=(.*)$")
	if k then job[k] = v end
end
meta.metaPath = job.meta

if emu.getsystemid() ~= "NES" then
	finish("ERROR", "wrong system id: " .. tostring(emu.getsystemid()))
end
if not movie.isloaded() then
	finish("ERROR", "no movie loaded")
end
meta.movieframes = movie.length()

pcall(function() client.speedmode(6400) end)
pcall(function() client.invisibleemulation(true) end)

-- Play to the end. The mode goes PLAY -> FINISHED on the last frame of the log.
local guard = movie.length() + 1000
local advanced = 0
while movie.mode() == "PLAY" do
	emu.frameadvance()
	advanced = advanced + 1
	if advanced > guard then
		finish("ERROR", "movie did not finish after " .. advanced .. " frames")
	end
end

meta.frames = emu.framecount()
meta.lag = emu.lagcount()

local ram = memory.read_bytes_as_array(0, 0x800, "RAM")
local chunks = {}
for i = 1, #ram do
	chunks[i] = string.char(ram[i])
end
writeAll(job.out, table.concat(chunks))

finish("OK", "")
