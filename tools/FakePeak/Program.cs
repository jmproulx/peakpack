// Fake PEAK.exe for the sandbox. Writes the arguments it received to launch-log.txt next to itself.
var dir = AppContext.BaseDirectory;
var line = $"{DateTime.Now:O} args: {string.Join(" | ", args)}";
File.AppendAllText(Path.Combine(dir, "launch-log.txt"), line + Environment.NewLine);
Console.WriteLine(line);
