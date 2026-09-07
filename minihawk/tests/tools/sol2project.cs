// Converts a quickerNES .sol input sequence into a Chimera project (.chimeraProject).
//
// The witness used to inject input frame by frame from Lua. A movie is what a
// user actually plays back, so the gate exercises that path instead: the movie
// session drives the controller chain natively and nothing per-frame runs in
// script. The project IS the movie (chimera's docs/project.md): one JSON file
// carrying the core pin, the settings, the header metadata and the input log.
// The zip movie the BizHawk lineage read no longer exists, and Chimera refuses
// anything that is not a project.
//
// The mnemonic layout is NOT hand-written here - LogEntryGenerator produces it
// from the core's own ControllerDefinition, which is the same code that reads
// the movie back. That definition is now narrowed by what the ports actually
// hold, so the settings this tool records and the columns it writes are one
// decision: change waterbox.config's controls or the port settings and the
// movies must be regenerated; the goldens will say so loudly.
//
// usage: sol2project <packageDir> <rom> <test.json> <sol> <out.chimeraProject>
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Chimera.Client.Common;
using Chimera.Emulation.Common;
using Chimera.Emulation.Common.Waterbox;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

internal static class Sol2Project
{
	// what the project format calls itself; a reader that finds another version
	// here is looking at a file this tool did not write
	private const string ProjectVersion = "Chimera Project File v1.1";

	private static readonly string[] JoypadOrder = { "Up", "Down", "Left", "Right", "Start", "Select", "B", "A" };

	private static string[] SplitFields(string line)
	{
		var parts = line.Split('|');
		// the line starts and ends with '|', so the first and last pieces are empty
		var fields = new List<string>();
		for (int i = 1; i < parts.Length - 1; i++) fields.Add(parts[i]);
		return fields.ToArray();
	}

	private static void DecodeJoypad(string s, string prefix, SimpleController c)
	{
		for (int i = 0; i < 8 && i < s.Length; i++)
		{
			c[prefix + " " + JoypadOrder[i]] = s[i] != '.' && s[i] != ' ';
		}
	}

	private static void DecodeArkanoid(string s, out int pot, out bool fire)
	{
		var potText = s.Length >= 5 ? s.Substring(2, 3).Trim() : "0";
		int.TryParse(potText, out pot);
		fire = s.Length >= 7 && s[6] == 'F';
	}

	public static int Main(string[] args)
	{
		if (args.Length < 5)
		{
			Console.Error.WriteLine("usage: sol2project <packageDir> <rom> <test.json> <sol> <out.chimeraProject>");
			return 2;
		}
		string pkg = args[0], romPath = args[1], testPath = args[2], solPath = args[3], outPath = args[4];

		var test = JObject.Parse(File.ReadAllText(testPath));
		var c1 = (string)test["Controller 1 Type"] ?? "Joypad";
		var c2 = (string)test["Controller 2 Type"] ?? "None";

		// The peripheral in each port is a core setting; carrying it in the project is
		// better than the config side-channel the harness used to write, because it
		// travels with the input it belongs to. The spellings are waterbox.config's
		// own enum options - a value the declaration does not offer is not a setting,
		// it is a typo the core silently replaces with the default.
		string port1 = "gamepad";
		if (c1 == "ArkanoidNES") port1 = "arkanoidNES";
		else if (c1 == "ArkanoidFamicom") port1 = "arkanoidFamicom";
		else if (c1 == "FourScore1") port1 = "fourScore";
		string port2 = c2 == "FourScore2" ? "fourScore" : "none";

		var cfg = WaterboxConfig.FromJson(File.ReadAllText(Path.Combine(pkg, "waterbox.config")));
		var settings = new WaterboxCoreSettings
		{
			Values = new Dictionary<string, object> { { "port1", port1 }, { "port2", port2 } },
		};
		var rom = File.ReadAllBytes(romPath);
		var core = new WaterboxCore(rom, romPath, cfg, pkg, settings);
		// The definition the core hands back is the one the MACHINE has: the ports
		// were read at boot, so a port holding nothing contributes no columns.
		var def = core.ControllerDefinition;
		// the generator needs the per-system mnemonic letters resolved first
		def.BuildMnemonicsCache(cfg.SystemId);
		var controller = new SimpleController(def);

		var entries = new List<string>();
		foreach (var raw in File.ReadAllLines(solPath))
		{
			var line = raw.TrimEnd('\r');
			if (line.Length == 0 || line[0] != '|') continue;
			var fields = SplitFields(line);
			controller.Clear();

			int fi = 1; // field 0 is the console (reset/power) field, which the native
			            // tester parses and then ignores during replay
			if (c1 == "ArkanoidNES")
			{
				int pot; bool fire;
				DecodeArkanoid(fields[fi], out pot, out fire);
				controller.AcceptNewAxis("P2 Paddle", pot);
				controller["P2 Fire"] = fire;
			}
			else if (c1 == "ArkanoidFamicom")
			{
				DecodeJoypad(fields[fi], "P1", controller);
				fi += 2; // skip the unsupported famicom expansion field
				int pot; bool fire;
				DecodeArkanoid(fields[fi], out pot, out fire);
				controller.AcceptNewAxis("P3 Paddle", pot);
				controller["P3 Fire"] = fire;
			}
			else
			{
				if (c1 == "Joypad") { DecodeJoypad(fields[fi], "P1", controller); fi++; }
				else if (c1 == "FourScore1") { DecodeJoypad(fields[fi], "P1", controller); DecodeJoypad(fields[fi + 1], "P3", controller); fi += 2; }

				if (c2 == "Joypad") { DecodeJoypad(fields[fi], "P2", controller); fi++; }
				else if (c2 == "FourScore2") { DecodeJoypad(fields[fi], "P2", controller); DecodeJoypad(fields[fi + 1], "P4", controller); fi += 2; }
			}

			entries.Add(LogEntryGenerator.GenerateLogEntry(controller));
		}

		string sha1;
		using (var sha = SHA1.Create()) sha1 = BitConverter.ToString(sha.ComputeHash(rom)).Replace("-", "");

		var log = new StringBuilder();
		log.Append("[Input]\n");
		log.Append("LogKey:").Append(LogEntryGenerator.GenerateLogKey(def)).Append('\n');
		foreach (var e in entries) log.Append(e).Append('\n');
		log.Append("[/Input]\n");

		// The core pin carries the NAME the core registry knows this package by
		// (waterbox.config's coreName) and nothing else: a witness movie must
		// replay against whatever build is under test, so pinning a version or a
		// package hash here would refuse the very thing the gate exists to check.
		var project = new JObject
		{
			["title"] = Path.GetFileNameWithoutExtension(romPath),
			["description"] = $"miniHawk witness (converted from {Path.GetFileName(solPath)})",
			["core"] = new JObject { ["name"] = cfg.CoreName, ["version"] = "", ["sha1"] = "" },
			["rerecords"] = 0,
			["settings"] = new JObject { ["port1"] = port1, ["port2"] = port2 },
			["headers"] = new JObject
			{
				["MovieVersion"] = ProjectVersion,
				["Platform"] = cfg.SystemId,
				["SHA1"] = sha1,
				["Author"] = "miniHawk witness",
			},
			["input"] = log.ToString(),
		};
		File.WriteAllText(outPath, project.ToString(Formatting.Indented));

		core.Dispose();
		Console.WriteLine($"{Path.GetFileName(outPath)}: {entries.Count} frames, port1={port1} port2={port2}");
		return 0;
	}
}
