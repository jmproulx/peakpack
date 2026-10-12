using System;
using System.Collections.Generic;
using System.IO;
using Mono.Cecil;
using Mono.Cecil.Cil;

namespace PeakPack.Tools
{
    /// <summary>
    /// Scans this mod's own IL for direct references to non-public members/types of OTHER assemblies (the game,
    /// Photon, Unity...). PEAK's Mono runtime throws FieldAccessException/MethodAccessException for those when the
    /// method is JIT-compiled, every call, even if the line never runs. Run at startup before any patch is applied;
    /// if anything is found the plugin stays inert. No Unity/game dependencies, so it can also be run offline.
    /// </summary>
    public static class IlAccessScan
    {
        public static List<string> Scan(string dllPath, IEnumerable<string> searchDirs, out int unresolved)
        {
            unresolved = 0;
            var problems = new List<string>();
            var resolver = new DefaultAssemblyResolver();
            foreach (var d in searchDirs) if (!string.IsNullOrEmpty(d) && Directory.Exists(d)) resolver.AddSearchDirectory(d);
            resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(dllPath)));
            using (var asm = AssemblyDefinition.ReadAssembly(dllPath, new ReaderParameters { AssemblyResolver = resolver, ReadSymbols = false }))
            {
                string self = asm.Name.Name;
                foreach (var module in asm.Modules)
                foreach (var type in module.GetTypes())
                foreach (var method in type.Methods)
                {
                    if (!method.HasBody) continue;
                    foreach (var ins in method.Body.Instructions)
                    {
                        string issue = null;
                        try
                        {
                            switch (ins.Operand)
                            {
                                case FieldReference fr when !IsSelf(fr.DeclaringType, self):
                                {
                                    var fd = fr.Resolve();
                                    if (fd == null) { unresolved++; break; }
                                    if (fd.IsPrivate || fd.IsAssembly || fd.IsFamilyAndAssembly) issue = $"field {fd.DeclaringType.FullName}.{fd.Name} ({Vis(fd.Attributes & FieldAttributes.FieldAccessMask)})";
                                    else issue = TypeIssue(fd.DeclaringType);
                                    break;
                                }
                                case MethodReference mr when !IsSelf(mr.DeclaringType, self):
                                {
                                    var md = mr.Resolve();
                                    if (md == null) { unresolved++; break; }
                                    if (md.IsPrivate || md.IsAssembly || md.IsFamilyAndAssembly) issue = $"method {md.DeclaringType.FullName}.{md.Name} ({Vis(md.Attributes & MethodAttributes.MemberAccessMask)})";
                                    else issue = TypeIssue(md.DeclaringType);
                                    break;
                                }
                                case TypeReference tr when !IsSelf(tr, self):
                                {
                                    var td = tr.Resolve();
                                    if (td == null) { unresolved++; break; }
                                    issue = TypeIssue(td);
                                    break;
                                }
                            }
                        }
                        catch (Exception e) { unresolved++; _ = e; }
                        if (issue != null) problems.Add($"{type.FullName}.{method.Name}: {issue}");
                    }
                }
            }
            return problems;
        }

        private static bool IsSelf(TypeReference t, string self)
        {
            while (t is TypeSpecification ts) t = ts.ElementType;
            var scope = t.Scope;
            if (scope is ModuleDefinition) return true; // defined in this module
            return scope != null && (scope.Name == self || scope.Name == self + ".dll");
        }

        private static string TypeIssue(TypeDefinition td)
        {
            for (var t = td; t != null; t = t.DeclaringType)
            {
                if (!t.IsNested) { if (!t.IsPublic) return $"type {td.FullName} (not public)"; break; }
                if (t.IsNestedPrivate || t.IsNestedAssembly || t.IsNestedFamilyAndAssembly) return $"type {td.FullName} (nested non-public)";
            }
            return null;
        }

        private static string Vis(object a) => a.ToString();
    }
}
