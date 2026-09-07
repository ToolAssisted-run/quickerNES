// Converts a quickerNES .sol input sequence into a miniHawk .tas movie.
//
// The witness used to inject input frame by frame from Lua. A movie is what a
// user actually plays back, so the gate now exercises that path instead: the
// movie session drives the controller chain natively and nothing per-frame runs
// in script.
//
// The mnemonic layout is NOT hand-written here - Bk2LogEntryGenerator produces
// it from the core's own ControllerDefinition, which is the same code that reads
// the movie back. Change waterbox.config's controls and the movies must be
// regenerated; the goldens will say so loudly.
//
// usage: sol2tas <packageDir> <rom> <test.json> <sol> <out.tas>
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using BizHawk.Client.Common;
using BizHawk.Emulation.Common;
using BizHawk.Emulation.Common.Waterbox;
using Newtonsoft.Json.Linq;

internal static class Sol2Tas
{
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

	private static void Put(ZipArchive zip, string name, string content)
	{
		var entry = zip.CreateEntry(name, CompressionLevel.Optimal);
		using (var w = new StreamWriter(entry.Open())) w.Write(content);
	}

	public static int Main(string[] args)
	{
		if (args.Length < 5)
		{
			Console.Error.WriteLine("usage: sol2tas <packageDir> <rom> <test.json> <sol> <out.tas>");
			return 2;
		}
		string pkg = args[0], romPath = args[1], testPath = args[2], solPath = args[3], outPath = args[4];

		var test = JObject.Parse(File.ReadAllText(testPath));
		var c1 = (string)test["Controller 1 Type"] ?? "Joypad";
		var c2 = (string)test["Controller 2 Type"] ?? "None";

		// The peripheral in each port is a core setting; carrying it in the movie is
		// better than the config side-channel the harness used to write, because it
		// travels with the input it belongs to.
		string port1 = "gamepad";
		if (c1 == "ArkanoidNES") port1 = "arkanoidNES";
		else if (c1 == "ArkanoidFamicom") port1 = "arkanoidFamicom";
		else if (c1 == "FourScore1") port1 = "fourscore";
		string port2 = c2 == "FourScore2" ? "fourscore" : "none";

		var cfg = WaterboxConfig.FromJson(File.ReadAllText(Path.Combine(pkg, "waterbox.config")));
		var settings = new WaterboxCoreSettings
		{
			Values = new Dictionary<string, object> { { "port1", port1 }, { "port2", port2 } },
		};
		var rom = File.ReadAllBytes(romPath);
		var core = new WaterboxCore(rom, cfg, Path.Combine(pkg, "core.wbx"), settings);
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

			entries.Add(Bk2LogEntryGenerator.GenerateLogEntry(controller));
		}

		string sha1;
		using (var sha = SHA1.Create()) sha1 = BitConverter.ToString(sha.ComputeHash(rom)).Replace("-", "");

		var header = new StringBuilder();
		header.AppendLine($"{HeaderKeys.MovieVersion} BizHawk v2.0.0");
		header.AppendLine($"{HeaderKeys.Platform} {cfg.SystemId}");
		// The name the CORE REGISTRY knows this package by (waterbox.config's
		// coreName, which is what WaterboxCoreFactory reports) - not the adapter's
		// [PortedCore] attribute, which is "Waterbox" for every waterbox core alike.
		// Get it wrong and playback stops on a "No such core" dialog.
		header.AppendLine($"{HeaderKeys.Core} {cfg.CoreName}");
		header.AppendLine($"{HeaderKeys.GameName} {Path.GetFileNameWithoutExtension(romPath)}");
		header.AppendLine($"{HeaderKeys.Sha1} {sha1}");
		header.AppendLine($"{HeaderKeys.Author} miniHawk witness (converted from {Path.GetFileName(solPath)})");
		header.AppendLine($"{HeaderKeys.Rerecords} 0");

		var log = new StringBuilder();
		log.AppendLine("[Input]");
		log.AppendLine($"LogKey:{Bk2LogEntryGenerator.GenerateLogKey(def)}");
		foreach (var e in entries) log.AppendLine(e);
		log.AppendLine("[/Input]");

		if (File.Exists(outPath)) File.Delete(outPath);
		using (var zip = ZipFile.Open(outPath, ZipArchiveMode.Create))
		{
			Put(zip, "Header.txt", header.ToString());
			Put(zip, "Comments.txt", "");
			Put(zip, "Subtitles.txt", "");
			Put(zip, "SyncSettings.json", ConfigService.SaveWithType(sync));
			Put(zip, "Input Log.txt", log.ToString());
		}

		core.Dispose();
		Console.WriteLine($"{Path.GetFileName(outPath)}: {entries.Count} frames, port1={port1} port2={port2}");
		return 0;
	}
}
