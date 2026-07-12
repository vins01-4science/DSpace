/**
 * The contents of this file are subject to the license and copyright
 * detailed in the LICENSE and NOTICE files at the root of the source
 * tree and available online at
 *
 * http://www.dspace.org/license/
 */
import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

import org.jacoco.core.tools.ExecFileLoader;
import org.jacoco.core.data.ExecutionData;
import org.jacoco.core.data.ExecutionDataStore;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.FieldVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.Type;

/**
 * Single-file tool that builds and queries a test/class dependency graph for
 * change-impact analysis. Run with {@code java TestGraph.java <cmd> [options]}.
 *
 * <p>Commands:
 * <ul>
 *   <li>{@code static}   - extract DSpace-only static reference edges via ASM</li>
 *   <li>{@code build}    - combine per-test .exec coverage + static edges into an impact index (SQLite)</li>
 *   <li>{@code impacted} - given a changed source file, list the tests to re-run</li>
 *   <li>{@code validate} - sanity-check the generated graph</li>
 * </ul>
 */
public class TestGraph {

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            usage();
            System.exit(2);
        }
        Map<String, String> opts = parseArgs(args, 1);
        switch (args[0]) {
            case "static":   staticCmd(opts); break;
            case "build":    buildCmd(opts); break;
            case "impacted": impactedCmd(opts); break;
            case "validate": validateCmd(opts); break;
            default:
                usage();
                System.exit(2);
        }
    }

    // ---------------------------------------------------------------- static

    private static void staticCmd(Map<String, String> opts) throws IOException {
        Path module = Paths.get(require(opts, "module"));
        Path classes = module.resolve("target/classes");
        Path testClasses = module.resolve("target/test-classes");
        Path out = Paths.get(opts.getOrDefault("out",
                module.resolve("target/test-graph/edges.tsv").toString()));
        Files.createDirectories(out.getParent());

        Set<String> allClasses = new HashSet<>();
        collectClasses(classes, allClasses);
        collectClasses(testClasses, allClasses);

        Set<String> edges = new HashSet<>();
        extractRefs(classes, allClasses, edges);
        extractRefs(testClasses, allClasses, edges);

        StringBuilder sb = new StringBuilder();
        for (String e : new TreeSet<>(edges)) {
            sb.append(e).append('\n');
        }
        Files.writeString(out, sb.toString());
        System.out.println("static: " + allClasses.size() + " classes, "
                + edges.size() + " edges -> " + out);
    }

    private static void collectClasses(Path root, Set<String> out) throws IOException {
        if (!Files.exists(root)) return;
        try (var stream = Files.walk(root)) {
            stream.filter(p -> p.toString().endsWith(".class")).forEach(p -> {
                String fqcn = classFileToFqcn(p, root);
                // keep top-level class only (drop inner classes for the node set)
                int dollar = fqcn.indexOf('$');
                out.add(dollar >= 0 ? fqcn.substring(0, dollar) : fqcn);
            });
        }
    }

    private static void extractRefs(Path root, Set<String> allClasses, Set<String> edges) throws IOException {
        if (!Files.exists(root)) return;
        try (var stream = Files.walk(root)) {
            for (Path p : stream.filter(f -> f.toString().endsWith(".class")).toList()) {
                String from = classFileToFqcn(p, root);
                int dollar = from.indexOf('$');
                from = dollar >= 0 ? from.substring(0, dollar) : from;
                byte[] bytes = Files.readAllBytes(p);
                for (Ref r : referencesOf(bytes)) {
                    String to = r.to;
                    int d = to.indexOf('$');
                    to = d >= 0 ? to.substring(0, d) : to;
                    if (allClasses.contains(to) && !to.equals(from)) {
                        edges.add(from + "\t" + to + "\t" + r.kind);
                    }
                }
            }
        }
    }

    private static List<Ref> referencesOf(byte[] bytes) {
        List<Ref> refs = new ArrayList<>();
        try {
            ClassReader cr = new ClassReader(bytes);
            cr.accept(new ClassVisitor(Opcodes.ASM9) {
                @Override
                public void visit(int version, int access, String name, String signature,
                                  String superName, String[] interfaces) {
                    if (superName != null) refs.add(new Ref(internalToFqcn(superName), "extends"));
                    if (interfaces != null) {
                        for (String itf : interfaces) {
                            refs.add(new Ref(internalToFqcn(itf), "implements"));
                        }
                    }
                }

                @Override
                public FieldVisitor visitField(int access, String name, String descriptor,
                                              String signature, Object value) {
                    addDescTypes(descriptor, refs);
                    return null;
                }

                @Override
                public MethodVisitor visitMethod(int access, String name, String descriptor,
                                                 String signature, String[] exceptions) {
                    addMethodDescTypes(descriptor, refs);
                    if (exceptions != null) {
                        for (String ex : exceptions) refs.add(new Ref(internalToFqcn(ex), "throws"));
                    }
                    return new MethodVisitor(Opcodes.ASM9) {
                        @Override
                        public void visitMethodInsn(int opcode, String owner, String name,
                                                    String descriptor, boolean isInterface) {
                            refs.add(new Ref(internalToFqcn(owner), "uses"));
                            addMethodDescTypes(descriptor, refs);
                        }

                        @Override
                        public void visitFieldInsn(int opcode, String owner, String name, String descriptor) {
                            refs.add(new Ref(internalToFqcn(owner), "uses"));
                            addDescTypes(descriptor, refs);
                        }

                        @Override
                        public void visitTypeInsn(int opcode, String type) {
                            refs.add(new Ref(internalToFqcn(type), "uses"));
                        }

                        @Override
                        public void visitLocalVariable(String name, String descriptor, String signature,
                                                      org.objectweb.asm.Label start,
                                                      org.objectweb.asm.Label end, int index) {
                            addDescTypes(descriptor, refs);
                        }

                        @Override
                        public void visitTryCatchBlock(org.objectweb.asm.Label start,
                                                      org.objectweb.asm.Label end,
                                                      org.objectweb.asm.Label handler, String type) {
                            if (type != null) refs.add(new Ref(internalToFqcn(type), "uses"));
                        }

                        @Override
                        public org.objectweb.asm.AnnotationVisitor visitAnnotation(String descriptor, boolean visible) {
                            addDescTypes(descriptor, refs);
                            return null;
                        }
                    };
                }
            }, 0);
        } catch (Exception ignored) {
            // skip unreadable class files
        }
        return refs;
    }

    private static void addDescTypes(String desc, List<Ref> refs) {
        if (desc == null) return;
        try {
            Type t = Type.getType(desc);
            if (t.getSort() == Type.ARRAY) t = t.getElementType();
            if (t.getSort() == Type.OBJECT) refs.add(new Ref(t.getInternalName(), "uses"));
        } catch (Exception ignored) {
            // ignore
        }
    }

    private static void addMethodDescTypes(String desc, List<Ref> refs) {
        if (desc == null) return;
        try {
            for (Type a : Type.getArgumentTypes(desc)) addType(a, refs);
            addType(Type.getReturnType(desc), refs);
        } catch (Exception ignored) {
            // ignore
        }
    }

    private static void addType(Type t, List<Ref> refs) {
        if (t == null) return;
        if (t.getSort() == Type.ARRAY) t = t.getElementType();
        if (t.getSort() == Type.OBJECT) refs.add(new Ref(t.getInternalName(), "uses"));
    }

    // ------------------------------------------------------------------ build

    private static void buildCmd(Map<String, String> opts) throws Exception {
        Path module = Paths.get(require(opts, "module"));
        Path perTest = Paths.get(opts.getOrDefault("per-test",
                module.resolve("target/per-test").toString()));
        Path edgesFile = Paths.get(opts.getOrDefault("edges",
                module.resolve("target/test-graph/edges.tsv").toString()));
        Path db = Paths.get(opts.getOrDefault("db",
                module.resolve("target/test-graph/impact-index.sqlite").toString()));
        Files.createDirectories(db.getParent());

        // 1) static reference graph (DSpace-only)
        Map<String, Set<String>> refs = new HashMap<>();
        for (String line : Files.readAllLines(edgesFile)) {
            String[] parts = line.split("\t");
            if (parts.length < 2) continue;
            refs.computeIfAbsent(parts[0], k -> new HashSet<>()).add(parts[1]);
        }

        // 2) per-test runtime coverage
        Map<String, Set<String>> covered = new HashMap<>();
        if (Files.exists(perTest)) {
            try (var stream = Files.walk(perTest)) {
                for (Path exec : stream.filter(f -> f.toString().endsWith(".exec")).toList()) {
                    if (Files.size(exec) == 0) continue;
                    String key = exec.getFileName().toString();
                    key = key.substring(0, key.length() - ".exec".length());
                    Set<String> set = covered.computeIfAbsent(key, k -> new HashSet<>());
                    ExecFileLoader loader = new ExecFileLoader();
                    loader.load(exec.toFile());
                    ExecutionDataStore store = loader.getExecutionDataStore();
                    for (ExecutionData ed : store.getContents()) {
                        if (!ed.hasHits()) continue;
                        String n = ed.getName().replace('/', '.');
                        int d = n.indexOf('$');
                        if (d >= 0) n = n.substring(0, d);
                        set.add(n);
                    }
                }
            }
        }

        // 3) reverse impact closure: class -> tests whose covered set reaches it
        Map<String, Set<String>> impact = new HashMap<>();
        for (Map.Entry<String, Set<String>> e : covered.entrySet()) {
            String test = e.getKey();
            Set<String> closure = new HashSet<>();
            Deque<String> stack = new ArrayDeque<>(e.getValue());
            while (!stack.isEmpty()) {
                String n = stack.pop();
                if (!closure.add(n)) continue;
                Set<String> next = refs.get(n);
                if (next != null) {
                    for (String m : next) {
                        if (!closure.contains(m)) stack.push(m);
                    }
                }
            }
            for (String cls : closure) {
                impact.computeIfAbsent(cls, k -> new HashSet<>()).add(test);
            }
        }

        // 4) write SQLite
        Class.forName("org.sqlite.JDBC");
        try (Connection c = DriverManager.getConnection("jdbc:sqlite:" + db)) {
            c.setAutoCommit(false);
            c.createStatement().execute("DROP TABLE IF EXISTS class_refs");
            c.createStatement().execute("DROP TABLE IF EXISTS test_covers");
            c.createStatement().execute("DROP TABLE IF EXISTS impact");
            c.createStatement().execute("CREATE TABLE class_refs(from_c TEXT, to_c TEXT, kind TEXT)");
            c.createStatement().execute("CREATE TABLE test_covers(test TEXT, class TEXT)");
            c.createStatement().execute("CREATE TABLE impact(class TEXT, test TEXT)");
            try (PreparedStatement ps1 = c.prepareStatement("INSERT INTO class_refs VALUES (?,?,?)");
                 PreparedStatement ps2 = c.prepareStatement("INSERT INTO test_covers VALUES (?,?)");
                 PreparedStatement ps3 = c.prepareStatement("INSERT INTO impact VALUES (?,?)")) {
                for (Map.Entry<String, Set<String>> e : refs.entrySet()) {
                    for (String to : e.getValue()) {
                        ps1.setString(1, e.getKey());
                        ps1.setString(2, to);
                        ps1.setString(3, "reference");
                        ps1.addBatch();
                    }
                }
                for (Map.Entry<String, Set<String>> e : covered.entrySet()) {
                    for (String cls : e.getValue()) {
                        ps2.setString(1, e.getKey());
                        ps2.setString(2, cls);
                        ps2.addBatch();
                    }
                }
                for (Map.Entry<String, Set<String>> e : impact.entrySet()) {
                    for (String test : e.getValue()) {
                        ps3.setString(1, e.getKey());
                        ps3.setString(2, test);
                        ps3.addBatch();
                    }
                }
                ps1.executeBatch();
                ps2.executeBatch();
                ps3.executeBatch();
            }
            c.commit();
        }
        System.out.println("build: " + covered.size() + " tests, " + refs.size()
                + " classes-in-graph, " + impact.size() + " impacted classes -> " + db);
    }

    // --------------------------------------------------------------- impacted

    private static void impactedCmd(Map<String, String> opts) throws Exception {
        Path db = Paths.get(require(opts, "db"));
        String file = require(opts, "file");
        String fqcn = pathToFqcn(file);
        if (fqcn == null) {
            System.err.println("Cannot resolve '" + file + "' to a class. Pass a source path under "
                    + "src/main/java or src/test/java, or the fully-qualified class name.");
            System.exit(1);
        }
        Class.forName("org.sqlite.JDBC");
        try (Connection c = DriverManager.getConnection("jdbc:sqlite:" + db)) {
            System.out.println("Changed class: " + fqcn);
            try (PreparedStatement ps = c.prepareStatement(
                    "SELECT test FROM impact WHERE class = ? ORDER BY test")) {
                ps.setString(1, fqcn);
                try (ResultSet rs = ps.executeQuery()) {
                    boolean any = false;
                    System.out.println("Tests to re-run:");
                    while (rs.next()) {
                        any = true;
                        System.out.println("  " + rs.getString(1));
                    }
                    if (!any) System.out.println("  (none)");
                }
            }
        }
    }

    // ---------------------------------------------------------------- validate

    private static void validateCmd(Map<String, String> opts) throws Exception {
        Path module = Paths.get(require(opts, "module"));
        Path perTest = Paths.get(opts.getOrDefault("per-test",
                module.resolve("target/per-test").toString()));
        Path db = Paths.get(opts.getOrDefault("db",
                module.resolve("target/test-graph/impact-index.sqlite").toString()));

        // 1) at least one non-empty per-test exec
        long execCount = 0;
        if (Files.exists(perTest)) {
            try (var stream = Files.walk(perTest)) {
                execCount = stream.filter(f -> f.toString().endsWith(".exec") && sizeOf(f) > 0).count();
            }
        }
        if (execCount == 0) fail("No non-empty per-test .exec files found in " + perTest);

        Class.forName("org.sqlite.JDBC");
        try (Connection c = DriverManager.getConnection("jdbc:sqlite:" + db)) {
            long covers = count(c, "SELECT COUNT(*) FROM test_covers");
            if (covers == 0) fail("test_covers is empty");

            // round-trip: pick a covered class, ensure it maps back via impact
            String cls = null, tst = null;
            try (PreparedStatement ps = c.prepareStatement(
                    "SELECT class, test FROM test_covers LIMIT 1")) {
                try (ResultSet rs = ps.executeQuery()) {
                    if (rs.next()) { cls = rs.getString(1); tst = rs.getString(2); }
                }
            }
            long back = 0;
            if (cls != null) {
                try (PreparedStatement ps = c.prepareStatement(
                        "SELECT COUNT(*) FROM impact WHERE class = ? AND test = ?")) {
                    ps.setString(1, cls);
                    ps.setString(2, tst);
                    try (ResultSet rs = ps.executeQuery()) { if (rs.next()) back = rs.getLong(1); }
                }
            }
            if (back == 0) fail("Round-trip failed for class=" + cls + " test=" + tst);

            long impacts = count(c, "SELECT COUNT(*) FROM impact");
            long edges = count(c, "SELECT COUNT(*) FROM class_refs");
            System.out.println("validate OK: " + execCount + " exec files, " + covers
                    + " test_covers rows, " + edges + " edges, " + impacts + " impact rows");
        }
    }

    private static long count(Connection c, String sql) throws Exception {
        try (PreparedStatement ps = c.prepareStatement(sql);
             ResultSet rs = ps.executeQuery()) {
            return rs.next() ? rs.getLong(1) : 0;
        }
    }

    // ----------------------------------------------------------------- helpers

    private static String classFileToFqcn(Path file, Path root) {
        String p = root.relativize(file).toString();
        if (p.endsWith(".class")) p = p.substring(0, p.length() - 6);
        return p.replace(File.separatorChar, '.').replace('/', '.');
    }

    private static String internalToFqcn(String internal) {
        return internal.replace('/', '.');
    }

    private static String pathToFqcn(String path) {
        String s = Paths.get(path).toString();
        String markerMain = "src" + File.separator + "main" + File.separator + "java";
        String markerTest = "src" + File.separator + "test" + File.separator + "java";
        int i = s.indexOf(markerMain);
        if (i >= 0) return toFqcn(s.substring(i + markerMain.length() + 1));
        int j = s.indexOf(markerTest);
        if (j >= 0) return toFqcn(s.substring(j + markerTest.length() + 1));
        if (!s.endsWith(".java") && s.contains(".")) return s; // already an fqcn
        return null;
    }

    private static String toFqcn(String rel) {
        if (rel.endsWith(".java")) rel = rel.substring(0, rel.length() - 5);
        return rel.replace(File.separatorChar, '.').replace('/', '.');
    }

    private static long sizeOf(Path p) {
        try { return Files.size(p); } catch (IOException e) { return 0; }
    }

    private static void fail(String msg) {
        System.err.println("validate FAILED: " + msg);
        System.exit(1);
    }

    private static Map<String, String> parseArgs(String[] args, int from) {
        Map<String, String> m = new HashMap<>();
        for (int i = from; i < args.length; i++) {
            String a = args[i];
            if (a.startsWith("--") && i + 1 < args.length) {
                m.put(a.substring(2), args[++i]);
            }
        }
        return m;
    }

    private static String require(Map<String, String> opts, String key) {
        String v = opts.get(key);
        if (v == null) {
            System.err.println("Missing required option: --" + key);
            System.exit(2);
        }
        return v;
    }

    private static void usage() {
        System.out.println("Usage: java TestGraph.java <cmd> [options]");
        System.out.println("  static   --module <dir> [--out edges.tsv]");
        System.out.println("  build    --module <dir> [--per-test dir] [--edges file] [--db file]");
        System.out.println("  impacted --db <file> --file <source-path-or-fqcn>");
        System.out.println("  validate --module <dir> [--per-test dir] [--db file]");
    }

    private static final class Ref {
        final String to;
        final String kind;
        Ref(String to, String kind) { this.to = to; this.kind = kind; }
    }
}
