// Usage: IlScan <mod.dll> <searchDir>...
if (args.Length < 1) { System.Console.Error.WriteLine("usage: IlScan <dll> [searchDirs...]"); return 2; }
var dirs = new System.Collections.Generic.List<string>(args).GetRange(1, args.Length - 1);
var problems = PeakPack.Tools.IlAccessScan.Scan(args[0], dirs, out int unresolved);
if (unresolved > 0) System.Console.WriteLine($"IlScan: {unresolved} references could not be resolved (ignored).");
foreach (var p in problems) System.Console.Error.WriteLine("error PPK001: direct non-public access: " + p);
System.Console.WriteLine($"IlScan: {problems.Count} direct non-public references in {System.IO.Path.GetFileName(args[0])}.");
return problems.Count == 0 ? 0 : 1;
