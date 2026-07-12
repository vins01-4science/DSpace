/**
 * The contents of this file are subject to the license and copyright
 * detailed in the LICENSE and NOTICE files at the root of the source
 * tree and available online at
 *
 * http://www.dspace.org/license/
 */
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.EnumMap;
import java.util.Collection;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.jacoco.core.analysis.Analyzer;
import org.jacoco.core.analysis.ICoverageVisitor;
import org.jacoco.core.analysis.IClassCoverage;
import org.jacoco.core.analysis.IMethodCoverage;
import org.jacoco.core.analysis.ICounter;
import org.jacoco.core.analysis.ILine;
import org.jacoco.core.tools.ExecFileLoader;
import org.jacoco.core.data.ExecutionData;
import org.jacoco.core.data.ExecutionDataStore;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.Label;
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
 *   <li>{@code config}   - extract property/bean references + config/bean declarations</li>
 *   <li>{@code build}    - combine per-test .exec coverage + static edges + config into an impact index (SQLite)</li>
 *   <li>{@code impacted} - given a changed source file / property / config / bean, list the tests to re-run</li>
 *   <li>{@code validate} - sanity-check the generated graph</li>
 *   <li>{@code aggregate}- merge per-module indexes into a single repo-wide index</li>
 * </ul>
 */
public class TestGraph {

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

    // ----------------------------------------------------------------- config

    private static final Pattern RE_GETPROP =
            Pattern.compile("getProperty[A-Za-z]*\\(\\s*\"([^\"]+)\"");
    private static final Pattern RE_VALUE =
            Pattern.compile("@Value\\(\\s*\"\\$\\{([^}:]+)(?::[^}]*)?\\}\"");
    private static final Pattern RE_CFGPROPS =
            Pattern.compile("@ConfigurationProperties\\(\\s*(?:prefix\\s*=\\s*)?\"([^\"]+)\"");
    private static final Pattern RE_GETBEAN_CLASS =
            Pattern.compile("getBean\\(\\s*([\\w.$]+)\\.class\\s*\\)");
    private static final Pattern RE_GETBEAN_NAME =
            Pattern.compile("getBean\\(\\s*\"([^\"]+)\"");
    private static final Pattern RE_RESNAME =
            Pattern.compile("@Resource\\(\\s*name\\s*=\\s*\"([^\"]+)\"");
    private static final Pattern RE_INJ =
            Pattern.compile("@(Autowired|Resource|Inject)\\b");
    private static final Pattern RE_BEAN =
            Pattern.compile("@Bean\\b");
    private static final Pattern RE_TYPE_TOKEN =
            Pattern.compile("([A-Z][\\w]*(?:\\.[A-Z][\\w]*)*(?:<[^>]*>)?)");
    private static final Pattern RE_METHOD_RET =
            Pattern.compile("(\\b[A-Z][\\w.<>\\[\\],\\s]*?)\\s+\\w+\\s*\\(");

    // Curated mapping: DSpace XML metadata/form config files -> consumer classes.
    // These files contain no <bean>/id attributes, so the generic extractor would
    // ignore them. A change to such a file is mapped to the tests impacted by its
    // consumer(s) via the existing class impact. Narrow per the registry-breadth choice.
    private static final Map<String, String[]> CONFIG_CONSUMERS_BY_BASENAME = Map.of(
            "submission-forms.xml", new String[]{
                    "org.dspace.app.util.DCInputsReader",
                    "org.dspace.app.util.DCInput",
                    "org.dspace.app.util.Util",
                    "org.dspace.content.authority.DCInputAuthority"},
            "item-submission.xml", new String[]{
                    "org.dspace.app.util.SubmissionConfigReader",
                    "org.dspace.submit.service.SubmissionConfigServiceImpl",
                    "org.dspace.content.authority.MetadataAuthorityServiceImpl",
                    "org.dspace.content.edit.service.impl.EditItemModeServiceImpl",
                    "org.dspace.validation.service.impl.ValidationServiceImpl"});
    private static final String[] REGISTRY_CONSUMERS = {
            "org.dspace.administer.MetadataImporter",
            "org.dspace.administer.RegistryLoader"};

    /**
     * Kind of config entity that changed, used to pick the precise consumer methods for
     * {@code refine --configfile} method-level narrowing. Keying by kind (not by config file)
     * means a change to ONE entity pulls only the consumer methods that read THAT entity, not
     * the whole config's method set.
     */
    private enum CfgKind { FORM, NAMEMAP, STEP, FIELD, METADATA, REGISTRY }

    /** A changed config entity: its kind plus the matched value (form/step/field/entity-type...). */
    private static final class ConfigEntity {
        final CfgKind kind;
        final String value;
        ConfigEntity(CfgKind kind, String value) { this.kind = kind; this.value = value; }
        public boolean equals(Object o) {
            if (this == o) return true;
            if (!(o instanceof ConfigEntity)) return false;
            ConfigEntity e = (ConfigEntity) o;
            return kind == e.kind && value.equals(e.value);
        }
        public int hashCode() { return 31 * kind.hashCode() + value.hashCode(); }
    }

    /**
     * Curated config-entity change -> consumer (class, method) map used by {@code refine --configfile}
     * for method-level narrowing. A {@code null} method means the whole class is the relevant code
     * portion (class-level). Keyed by the kind of config entity that changed. Extension point:
     * widen/narrow the method list per entity kind to trade precision against recall.
     */
    private static final Map<CfgKind, List<ClassMethod>> CONFIG_ENTITY_CONSUMERS = new EnumMap<>(CfgKind.class);
    static {
        CONFIG_ENTITY_CONSUMERS.put(CfgKind.FORM, List.of(
                new ClassMethod("org.dspace.app.util.DCInputsReader", "getInputsByFormName"),
                new ClassMethod("org.dspace.app.util.DCInputsReader", "getInputsBySubmissionName")));
        // entity-type -> submission-name binding lives in item-submission.xml <name-map> and applies
        // ONLY to workspace & workflow items (they carry a defined entity-type from their collection).
        // Consumers are the resolution path plus the workspace/workflow REST submission converters.
        CONFIG_ENTITY_CONSUMERS.put(CfgKind.NAMEMAP, List.of(
                new ClassMethod("org.dspace.app.util.SubmissionConfigReader", "getEntityTypeSubmission"),
                new ClassMethod("org.dspace.app.util.SubmissionConfigReader", "getSubmissionConfigByCollection"),
                new ClassMethod("org.dspace.app.util.SubmissionConfigReader", "processMap"),
                new ClassMethod("org.dspace.submit.service.SubmissionConfigServiceImpl", "getSubmissionConfigByCollection"),
                new ClassMethod("org.dspace.app.rest.converter.AInprogressItemConverter", "convert"),
                new ClassMethod("org.dspace.app.rest.repository.WorkspaceItemRestRepository", "convert"),
                new ClassMethod("org.dspace.app.rest.converter.WorkflowItemConverter", "convert"),
                new ClassMethod("org.dspace.app.rest.converter.ClaimedTaskConverter", "convert"),
                new ClassMethod("org.dspace.app.rest.converter.PoolTaskConverter", "convert")));
        CONFIG_ENTITY_CONSUMERS.put(CfgKind.STEP, List.of(
                new ClassMethod("org.dspace.app.util.SubmissionConfigReader", "getStepConfig"),
                new ClassMethod("org.dspace.app.util.SubmissionConfigReader", "getSubmissionConfigByInProgressSubmission")));
        // A metadata <field> (dot: dc.contributor.author) OR a comma-list of fields is consumed by the
        // metadata services: authority/choice read dot keys; security reads the comma-list
        // (metadata.publicField) with dot + .*/dc.* wildcards; validation + submission-field diff read
        // the form field. Both notations are therefore covered.
        CONFIG_ENTITY_CONSUMERS.put(CfgKind.FIELD, List.of(
                new ClassMethod("org.dspace.content.authority.MetadataAuthorityServiceImpl", "init"),
                new ClassMethod("org.dspace.content.authority.ChoiceAuthorityServiceImpl", "config2fkey"),
                new ClassMethod("org.dspace.content.authority.ChoiceAuthorityServiceImpl", "loadChoiceAuthorityConfigurations"),
                new ClassMethod("org.dspace.content.security.MetadataSecurityServiceImpl", "getPublicMetadataFromConfig"),
                new ClassMethod("org.dspace.content.security.MetadataSecurityServiceImpl", "metadataMatch"),
                new ClassMethod("org.dspace.validation.MetadataValidator", "validate"),
                new ClassMethod("org.dspace.app.util.Util", "differenceInSubmissionFields"),
                new ClassMethod("org.dspace.app.util.DCInput", "getSchema"),
                new ClassMethod("org.dspace.app.util.DCInput", "getElement"),
                new ClassMethod("org.dspace.app.util.DCInput", "getQualifier"),
                new ClassMethod("org.dspace.app.util.DCInput", "getLabel"),
                new ClassMethod("org.dspace.app.util.DCInput", "isRequired")));
        // A registry metadata-field (<dc-schema>/<dc-element>/<dc-qualifier>) change is consumed by the
        // registry importers and by the authority/choice services that read that field.
        CONFIG_ENTITY_CONSUMERS.put(CfgKind.METADATA, List.of(
                new ClassMethod("org.dspace.administer.MetadataImporter", "loadRegistry"),
                new ClassMethod("org.dspace.administer.RegistryLoader", "loadBitstreamFormats"),
                new ClassMethod("org.dspace.content.authority.MetadataAuthorityServiceImpl", "init"),
                new ClassMethod("org.dspace.content.authority.ChoiceAuthorityServiceImpl", "config2fkey")));
        CONFIG_ENTITY_CONSUMERS.put(CfgKind.REGISTRY, List.of(
                new ClassMethod("org.dspace.administer.MetadataImporter", "loadRegistry"),
                new ClassMethod("org.dspace.administer.RegistryLoader", "loadBitstreamFormats"),
                new ClassMethod("org.dspace.content.authority.MetadataAuthorityServiceImpl", "init")));
    }

    private static final class ClassMethod {
        final String cls;
        final String method; // null => whole class is relevant
        ClassMethod(String cls, String method) { this.cls = cls; this.method = method; }
    }

    private static void collectConfigConsumers(Path f, List<String[]> out) {
        String name = f.getFileName().toString();
        String[] classes = CONFIG_CONSUMERS_BY_BASENAME.get(name);
        if (classes != null) {
            for (String cls : classes) out.add(new String[]{f.toString(), cls});
        } else if (f.toString().contains("/config/registries/")
                || f.toString().contains("\\config\\registries\\")) {
            for (String cls : REGISTRY_CONSUMERS) out.add(new String[]{f.toString(), cls});
        }
    }

    private static void configCmd(Map<String, String> opts) throws IOException {
        Path module = Paths.get(require(opts, "module"));
        Path outDir = Paths.get(opts.getOrDefault("out",
                module.resolve("target/test-graph").toString()));
        Files.createDirectories(outDir);

        List<String[]> propRefs = new ArrayList<>();
        List<String[]> beanRefs = new ArrayList<>();
        List<String[]> configKeys = new ArrayList<>();
        List<String[]> beanDecls = new ArrayList<>();
        List<String[]> configConsumers = new ArrayList<>();

        // Java sources: property + bean references
        for (Path root : new Path[]{module.resolve("src/main/java"), module.resolve("src/test/java")}) {
            if (!Files.exists(root)) continue;
            try (var stream = Files.walk(root)) {
                for (Path f : stream.filter(p -> p.toString().endsWith(".java")).toList()) {
                    String from = javaSourceToFqcn(f);
                    if (from == null) continue;
                    String src = Files.readString(f, StandardCharsets.UTF_8);
                    extractJavaConfigRefs(from, src, propRefs, beanRefs, beanDecls);
                }
            }
        }

        // Resources: config keys (properties/cfg/yml) + bean declarations (XML)
        for (Path root : new Path[]{module.resolve("src/main/resources"), module.resolve("src/test/resources")}) {
            if (!Files.exists(root)) continue;
            try (var stream = Files.walk(root)) {
                for (Path f : stream.filter(p -> {
                    String n = p.toString();
                    return n.endsWith(".properties") || n.endsWith(".cfg")
                            || n.endsWith(".yml") || n.endsWith(".yaml")
                            || n.endsWith(".xml");
                }).toList()) {
                    String rel = f.toString();
                    if (rel.endsWith(".xml")) {
                        extractXmlConfig(f, configKeys, beanDecls);
                        collectConfigConsumers(f, configConsumers);
                    } else {
                        extractPropertiesConfig(f, configKeys);
                    }
                }
            }
        }

        // Optional repo-wide config scan (cross-module properties / XML beans)
        String root = opts.get("root");
        if (root != null) {
            Path repo = Paths.get(root);
            try (var stream = Files.walk(repo)) {
                for (Path f : stream.filter(p -> {
                    String n = p.toString();
                    return (n.endsWith(".properties") || n.endsWith(".cfg")
                            || n.endsWith(".yml") || n.endsWith(".yaml")
                            || n.endsWith(".xml"))
                            && n.contains("config");
                }).toList()) {
                    if (f.toString().endsWith(".xml")) {
                        extractXmlConfig(f, configKeys, beanDecls);
                        collectConfigConsumers(f, configConsumers);
                    } else {
                        extractPropertiesConfig(f, configKeys);
                    }
                }
            }
        }

        writeTsv(outDir.resolve("property_refs.tsv"), propRefs);
        writeTsv(outDir.resolve("bean_refs.tsv"), beanRefs);
        writeTsv(outDir.resolve("config_keys.tsv"), configKeys);
        writeTsv(outDir.resolve("bean_decls.tsv"), beanDecls);
        writeTsv(outDir.resolve("config_consumers.tsv"), configConsumers);
        System.out.println("config: " + propRefs.size() + " property refs, " + beanRefs.size()
                + " bean refs, " + configKeys.size() + " config keys, " + beanDecls.size()
                + " bean decls, " + configConsumers.size() + " config consumers -> " + outDir);
    }

    private static void extractJavaConfigRefs(String from, String src,
                                              List<String[]> propRefs,
                                              List<String[]> beanRefs,
                                              List<String[]> beanDecls) {
        for (Matcher m = RE_GETPROP.matcher(src); m.find();) {
            propRefs.add(new String[]{from, m.group(1), "cfg-read"});
        }
        for (Matcher m = RE_VALUE.matcher(src); m.find();) {
            propRefs.add(new String[]{from, m.group(1), "value"});
        }
        for (Matcher m = RE_CFGPROPS.matcher(src); m.find();) {
            propRefs.add(new String[]{from, m.group(1), "config-props"});
        }
        for (Matcher m = RE_GETBEAN_CLASS.matcher(src); m.find();) {
            beanRefs.add(new String[]{from, m.group(1), "bean-consumer-type"});
        }
        for (Matcher m = RE_GETBEAN_NAME.matcher(src); m.find();) {
            beanRefs.add(new String[]{from, m.group(1), "bean-consumer-name"});
        }
        for (Matcher m = RE_RESNAME.matcher(src); m.find();) {
            beanRefs.add(new String[]{from, m.group(1), "bean-consumer-name"});
        }
        // @Autowired / @Resource / @Inject -> following type token(s)
        Matcher inj = RE_INJ.matcher(src);
        while (inj.find()) {
            int pos = inj.end();
            String around = src.substring(pos, Math.min(pos + 400, src.length()));
            Matcher t = RE_TYPE_TOKEN.matcher(around);
            if (t.find()) {
                beanRefs.add(new String[]{from, t.group(1), "bean-consumer-type"});
            }
        }
        // @Bean -> preceding method return type (declaration)
        Matcher bean = RE_BEAN.matcher(src);
        while (bean.find()) {
            int start = bean.start();
            String before = src.substring(Math.max(0, start - 400), start);
            Matcher r = RE_METHOD_RET.matcher(before);
            String ret = null;
            while (r.find()) ret = r.group(1).trim();
            if (ret != null && !ret.isEmpty()) {
                beanDecls.add(new String[]{from, ret, ""});
            }
        }
    }

    private static void extractPropertiesConfig(Path file, List<String[]> configKeys) throws IOException {
        String fp = file.toString();
        try (var lines = Files.lines(file, StandardCharsets.UTF_8)) {
            boolean inMultiline = false;
            for (String raw : (Iterable<String>) lines::iterator) {
                String line = raw.trim();
                if (line.isEmpty() || line.startsWith("#") || line.startsWith("!")) continue;
                if (inMultiline && !line.endsWith("\\")) inMultiline = false;
                int eq = line.indexOf('=');
                int colon = line.indexOf(':');
                int split = -1;
                if (eq >= 0 && colon >= 0) split = Math.min(eq, colon);
                else if (eq >= 0) split = eq;
                else if (colon >= 0) split = colon;
                if (split < 0) {
                    if (line.endsWith("\\")) inMultiline = true;
                    continue;
                }
                String key = line.substring(0, split).trim();
                if (key.isEmpty()) continue;
                configKeys.add(new String[]{fp, key});
                if (line.endsWith("\\")) inMultiline = true;
            }
        }
        // file sentinel so --configfile returns tests touching the file itself
        configKeys.add(new String[]{fp, fp});
    }

    private static void extractXmlConfig(Path file, List<String[]> configKeys,
                                         List<String[]> beanDecls) throws IOException {
        String fp = file.toString();
        String text = Files.readString(file, StandardCharsets.UTF_8);
        // Spring bean declarations
        Matcher bean = Pattern.compile("<bean\\b[^>]*").matcher(text);
        while (bean.find()) {
            String tag = bean.group(0);
            String id = attr(tag, "id");
            String type = attr(tag, "class");
            if (type != null) {
                beanDecls.add(new String[]{fp, type, id == null ? "" : id});
            }
        }
        // metadata XML: id / name attributes as pseudo-keys
        Matcher attr = Pattern.compile("\\b(?:id|name)\\s*=\\s*\"([^\"]+)\"").matcher(text);
        while (attr.find()) {
            configKeys.add(new String[]{fp, attr.group(1)});
        }
        configKeys.add(new String[]{fp, fp});
    }

    private static String attr(String tag, String name) {
        Matcher m = Pattern.compile(name + "\\s*=\\s*\"([^\"]*)\"").matcher(tag);
        return m.find() ? m.group(1) : null;
    }

    // ------------------------------------------------------------------ build

    private static void buildCmd(Map<String, String> opts) throws Exception {
        Path module = Paths.get(require(opts, "module"));
        Path perTest = Paths.get(opts.getOrDefault("per-test",
                module.resolve("target/per-test").toString()));
        Path edgesFile = Paths.get(opts.getOrDefault("edges",
                module.resolve("target/test-graph/edges.tsv").toString()));
        Path configDir = Paths.get(opts.getOrDefault("config",
                module.resolve("target/test-graph").toString()));
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

        // 3) config: property/bean refs + config/bean declarations
        List<String[]> propRefs = readTsv(configDir.resolve("property_refs.tsv"));
        List<String[]> beanRefs = readTsv(configDir.resolve("bean_refs.tsv"));
        List<String[]> configKeys = readTsv(configDir.resolve("config_keys.tsv"));
        List<String[]> beanDecls = readTsv(configDir.resolve("bean_decls.tsv"));
        List<String[]> configConsumers = readTsv(configDir.resolve("config_consumers.tsv"));

        // known class universe for folding bean edges
        Set<String> known = new HashSet<>();
        known.addAll(refs.keySet());
        refs.values().forEach(known::addAll);
        known.addAll(covered.keySet());

        // fold bean consumer edges (consumer -> bean type) so bean changes impact consumers
        Map<String, String> idToType = new HashMap<>();
        for (String[] d : beanDecls) {
            if (d.length >= 3 && !d[2].isEmpty()) idToType.put(d[2], d[1]);
        }
        for (String[] b : beanRefs) {
            String from = b[0], ref = b[1], kind = b[2];
            if (kind.equals("bean-consumer-type") || kind.equals("bean-decl-type")) {
                String t = topLevel(ref);
                if (known.contains(t)) refs.computeIfAbsent(from, k -> new HashSet<>()).add(t);
            } else if (kind.equals("bean-consumer-name")) {
                String t = idToType.get(ref);
                if (t != null) {
                    t = topLevel(t);
                    if (known.contains(t)) refs.computeIfAbsent(from, k -> new HashSet<>()).add(t);
                }
            }
        }

        // 4) reverse impact closure: class -> tests whose covered set reaches it
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

        // 5) property_impact: key -> tests (via property_refs -> class -> tests)
        Map<String, Set<String>> propImpact = new HashMap<>();
        for (String[] pr : propRefs) {
            String cls = topLevel(pr[0]);
            Set<String> tests = impact.get(cls);
            if (tests != null) {
                propImpact.computeIfAbsent(pr[1], k -> new HashSet<>()).addAll(tests);
            }
        }

        // 6) write SQLite
        Class.forName("org.sqlite.JDBC");
        try (Connection c = DriverManager.getConnection("jdbc:sqlite:" + db)) {
            c.setAutoCommit(false);
            String[] drops = {"class_refs", "test_covers", "impact",
                    "property_refs", "bean_refs", "config_keys", "bean_decls", "property_impact",
                    "config_consumers"};
            for (String t : drops) c.createStatement().execute("DROP TABLE IF EXISTS " + t);
            c.createStatement().execute("CREATE TABLE class_refs(from_c TEXT, to_c TEXT, kind TEXT)");
            c.createStatement().execute("CREATE TABLE test_covers(test TEXT, class TEXT)");
            c.createStatement().execute("CREATE TABLE impact(class TEXT, test TEXT)");
            c.createStatement().execute("CREATE TABLE property_refs(from_c TEXT, key TEXT, kind TEXT)");
            c.createStatement().execute("CREATE TABLE bean_refs(from_c TEXT, ref TEXT, kind TEXT)");
            c.createStatement().execute("CREATE TABLE config_keys(file TEXT, key TEXT)");
            c.createStatement().execute("CREATE TABLE bean_decls(file TEXT, bean_type TEXT, bean_id TEXT)");
            c.createStatement().execute("CREATE TABLE property_impact(key TEXT, test TEXT)");
            c.createStatement().execute("CREATE TABLE config_consumers(file TEXT, class TEXT)");
            try (PreparedStatement ps1 = c.prepareStatement("INSERT INTO class_refs VALUES (?,?,?)");
                 PreparedStatement ps2 = c.prepareStatement("INSERT INTO test_covers VALUES (?,?)");
                 PreparedStatement ps3 = c.prepareStatement("INSERT INTO impact VALUES (?,?)");
                 PreparedStatement ps4 = c.prepareStatement("INSERT INTO property_refs VALUES (?,?,?)");
                 PreparedStatement ps5 = c.prepareStatement("INSERT INTO bean_refs VALUES (?,?,?)");
                 PreparedStatement ps6 = c.prepareStatement("INSERT INTO config_keys VALUES (?,?)");
                 PreparedStatement ps7 = c.prepareStatement("INSERT INTO bean_decls VALUES (?,?,?)");
                 PreparedStatement ps8 = c.prepareStatement("INSERT INTO property_impact VALUES (?,?)");
                 PreparedStatement ps9 = c.prepareStatement("INSERT INTO config_consumers VALUES (?,?)")) {
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
                for (String[] r : propRefs) {
                    ps4.setString(1, r[0]); ps4.setString(2, r[1]); ps4.setString(3, r[2]); ps4.addBatch();
                }
                for (String[] r : beanRefs) {
                    ps5.setString(1, r[0]); ps5.setString(2, r[1]); ps5.setString(3, r[2]); ps5.addBatch();
                }
                for (String[] r : configKeys) {
                    if (r.length < 2) continue;
                    ps6.setString(1, r[0]); ps6.setString(2, r[1]); ps6.addBatch();
                }
                for (String[] r : beanDecls) {
                    ps7.setString(1, r[0]); ps7.setString(2, r[1]);
                    ps7.setString(3, r.length > 2 ? r[2] : ""); ps7.addBatch();
                }
                for (Map.Entry<String, Set<String>> e : propImpact.entrySet()) {
                    for (String test : e.getValue()) {
                        ps8.setString(1, e.getKey());
                        ps8.setString(2, test);
                        ps8.addBatch();
                    }
                }
                for (String[] r : configConsumers) {
                    if (r.length < 2) continue;
                    ps9.setString(1, r[0]); ps9.setString(2, r[1]); ps9.addBatch();
                }
                ps1.executeBatch(); ps2.executeBatch(); ps3.executeBatch();
                ps4.executeBatch(); ps5.executeBatch(); ps6.executeBatch();
                ps7.executeBatch(); ps8.executeBatch(); ps9.executeBatch();
            }
            c.commit();
        }
        System.out.println("build: " + covered.size() + " tests, " + refs.size()
                + " classes-in-graph, " + impact.size() + " impacted classes, "
                + propImpact.size() + " impacted properties -> " + db);
    }

    private static String topLevel(String fqcn) {
        int d = fqcn.indexOf('$');
        if (d >= 0) fqcn = fqcn.substring(0, d);
        // strip generics
        int g = fqcn.indexOf('<');
        if (g >= 0) fqcn = fqcn.substring(0, g);
        return fqcn;
    }

    // --------------------------------------------------------------- impacted

    private static void impactedCmd(Map<String, String> opts) throws Exception {
        Path db = Paths.get(require(opts, "db"));
        boolean csv = opts.containsKey("csv");
        Class.forName("org.sqlite.JDBC");
        try (Connection c = DriverManager.getConnection("jdbc:sqlite:" + db)) {
            Set<String> tests = new TreeSet<>();
            if (opts.containsKey("property")) {
                String key = opts.get("property");
                try (PreparedStatement ps = c.prepareStatement(
                        "SELECT test FROM property_impact WHERE key = ? ORDER BY test")) {
                    ps.setString(1, key);
                    try (ResultSet rs = ps.executeQuery()) {
                        while (rs.next()) tests.add(rs.getString(1));
                    }
                }
                emit(tests, csv, "Property: " + key);
            } else if (opts.containsKey("configfile")) {
                String path = opts.get("configfile");
                Set<String> keys = fileKeys(c, path);
                // property-key based impact (cfg/properties/yml + XML id/name attributes)
                try (PreparedStatement ps = c.prepareStatement(
                        "SELECT test FROM property_impact WHERE key = ?")) {
                    for (String k : keys) {
                        ps.setString(1, k);
                        try (ResultSet rs = ps.executeQuery()) {
                            while (rs.next()) tests.add(rs.getString(1));
                        }
                    }
                }
                // config-file -> consumer class -> impact(class) -> tests.
                // Covers XML metadata/form files (submission-forms.xml, item-submission.xml,
                // dspace/config/registries/*.xml) that have no <bean>/id attributes to key on.
                if (hasTable(c, "config_consumers")) {
                    try (PreparedStatement psC = c.prepareStatement(
                            "SELECT class FROM config_consumers WHERE " + fileMatchSql(path))) {
                        setFileParam(psC, path);
                        try (ResultSet rsC = psC.executeQuery()) {
                            while (rsC.next()) {
                                String cls = rsC.getString(1);
                                try (PreparedStatement psT = c.prepareStatement(
                                        "SELECT test FROM impact WHERE class = ?")) {
                                    psT.setString(1, cls);
                                    try (ResultSet rsT = psT.executeQuery()) {
                                        while (rsT.next()) tests.add(rsT.getString(1));
                                    }
                                }
                            }
                        }
                    }
                }
                emit(tests, csv, "Config file: " + path);
            } else if (opts.containsKey("bean")) {
                String bean = opts.get("bean");
                String type = bean.contains(".") ? topLevel(bean) : null;
                Set<String> types = new TreeSet<>();
                if (type != null) {
                    types.add(type);
                } else {
                    // resolve bean id -> declared types
                    try (PreparedStatement ps = c.prepareStatement(
                            "SELECT bean_type FROM bean_decls WHERE bean_id = ?")) {
                        ps.setString(1, bean);
                        try (ResultSet rs = ps.executeQuery()) {
                            while (rs.next()) types.add(topLevel(rs.getString(1)));
                        }
                    }
                }
                if (types.isEmpty()) {
                    if (!csv) System.err.println("Bean: " + bean + " -> (no matching bean type)");
                    return;
                }
                try (PreparedStatement ps = c.prepareStatement(
                        "SELECT test FROM impact WHERE class = ?")) {
                    for (String t : types) {
                        ps.setString(1, t);
                        try (ResultSet rs = ps.executeQuery()) {
                            while (rs.next()) tests.add(rs.getString(1));
                        }
                    }
                }
                emit(tests, csv, "Bean: " + bean + (type == null ? " (id)" : " (type)"));
            } else if (opts.containsKey("beanfile")) {
                String path = opts.get("beanfile");
                Set<String> types = new TreeSet<>();
                try (PreparedStatement ps = c.prepareStatement(
                        "SELECT bean_type FROM bean_decls WHERE " + fileMatchSql(path))) {
                    setFileParam(ps, path);
                    try (ResultSet rs = ps.executeQuery()) {
                        while (rs.next()) types.add(topLevel(rs.getString(1)));
                    }
                }
                if (types.isEmpty()) {
                    if (!csv) System.err.println("Bean file: " + path + " -> (no bean declarations indexed)");
                    return;
                }
                try (PreparedStatement ps = c.prepareStatement(
                        "SELECT test FROM impact WHERE class = ?")) {
                    for (String t : types) {
                        ps.setString(1, t);
                        try (ResultSet rs = ps.executeQuery()) {
                            while (rs.next()) tests.add(rs.getString(1));
                        }
                    }
                }
                emit(tests, csv, "Bean file: " + path);
            } else {
                String file = require(opts, "file");
                String fqcn = pathToFqcn(file);
                if (fqcn == null) {
                    System.err.println("Cannot resolve '" + file + "' to a class. Pass a source path under "
                            + "src/main/java or src/test/java, or the fully-qualified class name.");
                    System.exit(1);
                }
                try (PreparedStatement ps = c.prepareStatement(
                        "SELECT test FROM impact WHERE class = ? ORDER BY test")) {
                    ps.setString(1, fqcn);
                    try (ResultSet rs = ps.executeQuery()) {
                        while (rs.next()) tests.add(rs.getString(1));
                    }
                }
                emit(tests, csv, "Changed class: " + fqcn);
            }
        }
    }

    private static void emit(Set<String> tests, boolean csv, String label) {
        if (csv) {
            tests.forEach(System.out::println);
            return;
        }
        System.out.println(label);
        System.out.println("Tests to re-run (" + tests.size() + "):");
        if (tests.isEmpty()) System.out.println("  (none)");
        else tests.forEach(t -> System.out.println("  " + t));
    }

    private static Set<String> fileKeys(Connection c, String path) throws Exception {
        Set<String> keys = new TreeSet<>();
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT key FROM config_keys WHERE " + fileMatchSql(path))) {
            setFileParam(ps, path);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) keys.add(rs.getString(1));
            }
        }
        return keys;
    }

    private static String fileMatchSql(String path) {
        return "file = ? OR file LIKE ?";
    }

    private static void setFileParam(PreparedStatement ps, String path) throws Exception {
        Path p = Paths.get(path).toAbsolutePath().normalize();
        ps.setString(1, p.toString());
        ps.setString(2, "%" + File.separator + p.getFileName().toString());
    }

    private static boolean hasTable(Connection c, String name) throws Exception {
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?")) {
            ps.setString(1, name);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next();
            }
        }
    }

    // ----------------------------------------------------------------- refine

    /**
     * Method-level refinement: narrows class-level impact to the tests that actually
     * cover the changed lines/methods (from a git diff) using per-test JaCoCo line
     * coverage. Requires the module's per-test exec dir and compiled classes.
     */
    private static void refineCmd(Map<String, String> opts) throws Exception {
        Path db = Paths.get(require(opts, "db"));
        Path perTest = opts.containsKey("per-test") ? Paths.get(opts.get("per-test")) : null;
        Path classesDir = opts.containsKey("classes") ? Paths.get(opts.get("classes")) : null;
        boolean haveCoverage = perTest != null && classesDir != null;

        List<String> diffLines;
        if (opts.containsKey("diff")) {
            String d = opts.get("diff");
            if (d.equals("-")) {
                diffLines = Files.readAllLines(Paths.get("/dev/stdin"), StandardCharsets.UTF_8);
            } else {
                diffLines = Files.readAllLines(Paths.get(d), StandardCharsets.UTF_8);
            }
        } else if (opts.containsKey("base")) {
            diffLines = gitDiff(opts.get("base"), opts.getOrDefault("head", "HEAD"));
        } else if (opts.containsKey("configfile")) {
            // config-only refinement without an explicit diff: treat the config file's own
            // content as the diff so parseConfigEntities sees all entities -> class-level union.
            diffLines = Files.readAllLines(Paths.get(opts.get("configfile")), StandardCharsets.UTF_8);
        } else {
            System.err.println("refine requires --diff <file|-> or --base <ref> [--head <ref>] (or --configfile for config-only refinement)");
            System.exit(2);
            return;
        }

        // .java changes -> method/class line ranges (existing behavior)
        Map<String, Set<Integer>> javaChanged = parseDiff(diffLines);

        // config XML changes -> consumer method line ranges (item B)
        Map<String, Set<Integer>> methodLinesMap = new HashMap<>();
        Set<String> classOnly = new TreeSet<>();
        if (opts.containsKey("configfile")) {
            String cfg = opts.get("configfile");
            Set<ConfigEntity> entities = parseConfigEntities(diffLines, cfg);
            if (entities.isEmpty()) {
                // whole-file / unrecognized change -> class-level for all consumers
                classOnly.addAll(configConsumersFor(cfg));
            } else {
                boolean anyResolved = false;
                for (ConfigEntity e : entities) {
                    List<ClassMethod> cms = CONFIG_ENTITY_CONSUMERS.get(e.kind);
                    if (cms == null || cms.isEmpty()) {
                        classOnly.addAll(configConsumersFor(cfg));
                        continue;
                    }
                    anyResolved = true;
                    for (ClassMethod cm : cms) {
                        if (cm.method == null || classesDir == null) {
                            classOnly.add(cm.cls);
                        } else {
                            int[] lr = methodLines(classesDir, cm.cls, cm.method);
                            if (lr == null) classOnly.add(cm.cls);
                            else methodLinesMap.computeIfAbsent(cm.cls, k -> new TreeSet<>())
                                    .addAll(linesRange(lr[0], lr[1]));
                        }
                    }
                }
                if (!anyResolved) classOnly.addAll(configConsumersFor(cfg));
            }
        }

        Set<String> candidateClasses = new TreeSet<>();
        candidateClasses.addAll(javaChanged.keySet());
        candidateClasses.addAll(methodLinesMap.keySet());
        candidateClasses.addAll(classOnly);
        if (candidateClasses.isEmpty()) {
            System.out.println("refine: no changed .java files or recognized config changes detected in diff");
            return;
        }

        Class.forName("org.sqlite.JDBC");
        Set<String> candidates = new TreeSet<>();
        Set<String> configClasses = new TreeSet<>();
        configClasses.addAll(methodLinesMap.keySet());
        configClasses.addAll(classOnly);
        try (Connection c = DriverManager.getConnection("jdbc:sqlite:" + db)) {
            for (String fqcn : candidateClasses) {
                boolean isCfg = configClasses.contains(fqcn);
                // config changes: prefer DIRECT coverage (test_covers) so we don't explode via the
                // transitive reference closure; fall back to impact when nothing is directly covered.
                String tbl = (isCfg && haveCoverage) ? "test_covers" : "impact";
                try (PreparedStatement ps = c.prepareStatement("SELECT test FROM " + tbl + " WHERE class = ?")) {
                    ps.setString(1, topLevel(fqcn));
                    try (ResultSet rs = ps.executeQuery()) {
                        while (rs.next()) candidates.add(rs.getString(1));
                    }
                }
                if (isCfg && haveCoverage && !candidates.isEmpty()) {
                    // direct coverage found; keep it (precise)
                } else if (isCfg && haveCoverage) {
                    try (PreparedStatement ps = c.prepareStatement("SELECT test FROM impact WHERE class = ?")) {
                        ps.setString(1, topLevel(fqcn));
                        try (ResultSet rs = ps.executeQuery()) {
                            while (rs.next()) candidates.add(rs.getString(1));
                        }
                    }
                }
            }
        }

        if (!haveCoverage) {
            // No per-test exec / compiled classes: degrade to class-level union (same set as
            // `impacted --configfile`), never a false negative vs the class-level impact.
            if (opts.containsKey("csv")) { candidates.forEach(System.out::println); return; }
            System.out.println("refine: " + candidateClasses.size() + " changed classes, "
                    + candidates.size() + " tests (class-level union; no per-test coverage available)");
            System.out.println("Changed classes: " + candidateClasses);
            if (!methodLinesMap.isEmpty()) {
                System.out.println("Resolved consumer method line ranges (pass --per-test + --classes to narrow):");
                methodLinesMap.forEach((k, v) -> {
                    int lo = Collections.min(v), hi = Collections.max(v);
                    System.out.println("  " + k + " [" + lo + "-" + hi + "] (" + v.size() + " lines)");
                });
            }
            System.out.println("Tests to re-run (" + candidates.size() + "):");
            if (candidates.isEmpty()) System.out.println("  (none)");
            else candidates.forEach(t -> System.out.println("  " + t));
            return;
        }

        Set<String> inScope = new TreeSet<>();
        Map<String, Set<String>> touchedMethods = new HashMap<>();
        for (String test : candidates) {
            boolean hit = false;
            for (String fqcn : javaChanged.keySet()) {
                RefineHit rh = coversChangedLines(perTest, classesDir, test, topLevel(fqcn), javaChanged.get(fqcn));
                if (rh.hit) {
                    hit = true;
                    if (!rh.methods.isEmpty())
                        touchedMethods.computeIfAbsent(test, k -> new TreeSet<>()).addAll(rh.methods);
                }
            }
            // class-level config consumers: candidate already came from direct coverage -> include
            if (!classOnly.isEmpty()) hit = true;
            for (String fqcn : methodLinesMap.keySet()) {
                RefineHit rh = coversChangedLines(perTest, classesDir, test, topLevel(fqcn), methodLinesMap.get(fqcn));
                if (rh.hit) {
                    hit = true;
                    if (!rh.methods.isEmpty())
                        touchedMethods.computeIfAbsent(test, k -> new TreeSet<>()).addAll(rh.methods);
                }
            }
            if (hit) inScope.add(test);
        }

        if (opts.containsKey("csv")) {
            inScope.forEach(System.out::println);
            return;
        }
        System.out.println("refine: " + candidates.size() + " tests at class-level impact, "
                + inScope.size() + " tests actually cover changed lines/methods");
        System.out.println("Changed classes: " + candidateClasses);
        System.out.println("Tests to re-run (" + inScope.size() + "):");
        if (inScope.isEmpty()) System.out.println("  (none)");
        else for (String t : inScope) {
            Set<String> m = touchedMethods.get(t);
            System.out.println("  " + t + (m != null && !m.isEmpty() ? "  -> " + m : ""));
        }
    }

    private static final class RefineHit {
        boolean hit;
        Set<String> methods = new TreeSet<>();
    }

    private static RefineHit coversChangedLines(Path perTest, Path classesDir,
                                                String test, String fqcn, Set<Integer> changedLines) throws IOException {
        RefineHit rh = new RefineHit();
        Path exec = perTest.resolve(test + ".exec");
        if (!Files.exists(exec) || Files.size(exec) == 0) return rh;
        Path classFile = classesDir.resolve(fqcn.replace('.', File.separatorChar) + ".class");
        if (!Files.exists(classFile)) return rh;
        try {
            byte[] bytes = Files.readAllBytes(classFile);
            String internalName = new ClassReader(bytes).getClassName();
            ExecFileLoader loader = new ExecFileLoader();
            loader.load(exec.toFile());
            ExecutionDataStore dataStore = loader.getExecutionDataStore();
            ICoverageVisitor visitor = cov -> {
                if (!cov.getName().equals(internalName)) return;
                for (IMethodCoverage m : cov.getMethods()) {
                    int a = m.getFirstLine(), b = m.getLastLine();
                    if (a < 0 || b < 0) continue;
                    boolean changed = false, covered = false;
                    for (int l = a; l <= b; l++) {
                        if (!changedLines.contains(l)) continue;
                        changed = true;
                        ILine ctr = m.getLine(l);
                        if (ctr != null && ctr.getStatus() != ICounter.EMPTY) covered = true;
                    }
                    if (changed && covered) {
                        rh.hit = true;
                        rh.methods.add(m.getName());
                    }
                }
            };
            Analyzer analyzer = new Analyzer(dataStore, visitor);
            analyzer.analyzeClass(bytes, internalName);
        } catch (Exception ignored) {
            // cannot analyze this class/test; treat as not covering
        }
        return rh;
    }

    private static List<String> gitDiff(String base, String head) throws Exception {
        List<String> out = new ArrayList<>();
        ProcessBuilder pb = new ProcessBuilder("git", "diff", "--no-color", base, head);
        pb.redirectErrorStream(true);
        Process p = pb.start();
        try (var r = new java.io.BufferedReader(
                new java.io.InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = r.readLine()) != null) out.add(line);
        }
        p.waitFor();
        return out;
    }

    private static Map<String, Set<Integer>> parseDiff(List<String> lines) {
        Map<String, Set<Integer>> changed = new HashMap<>();
        String cur = null;
        Pattern hunk = Pattern.compile("^@@ -\\d+(?:,\\d+)? \\+(\\d+)(?:,\\d+)? @@");
        for (int i = 0; i < lines.size(); i++) {
            String line = lines.get(i);
            if (line.startsWith("+++ ")) {
                String p = line.substring(4).strip();
                if (p.equals("/dev/null")) { cur = null; continue; }
                if (p.startsWith("b/")) p = p.substring(2);
                cur = p;
            } else if (line.startsWith("@@")) {
                if (cur == null) continue;
                Matcher m = hunk.matcher(line);
                if (!m.find()) continue;
                int newLine = Integer.parseInt(m.group(1));
                int j = i + 1;
                while (j < lines.size()) {
                    String b = lines.get(j);
                    if (b.startsWith("@@") || b.startsWith("+++ ") || b.startsWith("--- ")) break;
                    if (b.startsWith("+") && !b.startsWith("+++")) {
                        changed.computeIfAbsent(cur, k -> new HashSet<>()).add(newLine);
                        newLine++;
                    } else if (b.startsWith("-")) {
                        // old line only
                    } else {
                        newLine++; // context line
                    }
                    j++;
                }
                i = j - 1;
            }
        }
        // keep only .java files mapped to an fqcn
        Map<String, Set<Integer>> javaChanged = new HashMap<>();
        for (Map.Entry<String, Set<Integer>> e : changed.entrySet()) {
            String fqcn = pathToFqcn(e.getKey());
            if (fqcn != null) javaChanged.put(fqcn, e.getValue());
        }
        return javaChanged;
    }

    // config-change-aware refinement helpers (item B)

    private static Set<String> configConsumersFor(String cfg) {
        Set<String> s = new TreeSet<>();
        String n = Paths.get(cfg.replace('\\', '/')).getFileName().toString();
        String[] classes = CONFIG_CONSUMERS_BY_BASENAME.get(n);
        if (classes != null) {
            for (String cls : classes) s.add(cls);
        } else if (cfg.replace('\\', '/').contains("/config/registries/")) {
            for (String cls : REGISTRY_CONSUMERS) s.add(cls);
        }
        return s;
    }

    /**
     * Extract changed config entities (field name, form name, name-map entity-type, step id,
     * registry dc-schema/element/qualifier) from the diff hunk of the given config file. Returns
     * an empty set for a whole-file add/delete or when no recognizable entity is touched -> caller
     * falls back to class-level. A single <field> value may be a comma-separated list; each entry
     * becomes its own FIELD entity (covers both dot and list notations).
     */
    private static Set<ConfigEntity> parseConfigEntities(List<String> lines, String cfgPath) {
        Set<ConfigEntity> ents = new TreeSet<>((a, b) -> {
            int c = a.kind.compareTo(b.kind);
            return c != 0 ? c : a.value.compareTo(b.value);
        });
        String want = Paths.get(cfgPath.replace('\\', '/')).getFileName().toString();
        boolean inCfg = false;
        Pattern field = Pattern.compile("<field\\b[^>]*\\bname=\"([^\"]+)\"");
        Pattern form = Pattern.compile("<form\\b[^>]*\\bname=\"([^\"]+)\"");
        Pattern namemap = Pattern.compile("<name-map\\b[^>]*\\bcollection-entity-type=\"([^\"]+)\"[^>]*\\bsubmission-name=\"([^\"]+)\"");
        Pattern namemap2 = Pattern.compile("<name-map\\b[^>]*\\bsubmission-name=\"([^\"]+)\"[^>]*\\bcollection-entity-type=\"([^\"]+)\"");
        Pattern step = Pattern.compile("<(?:step|step-definition)\\b[^>]*\\bid=\"([^\"]+)\"");
        Pattern schema = Pattern.compile("<dc-schema>([^<]+)</dc-schema>");
        Pattern element = Pattern.compile("<dc-element>([^<]+)</dc-element>");
        Pattern qualifier = Pattern.compile("<dc-qualifier>([^<]+)</dc-qualifier>");
        for (String line : lines) {
            if (line.startsWith("+++ ")) {
                String p = line.substring(4).strip();
                if (p.equals("/dev/null")) { inCfg = false; continue; }
                if (p.startsWith("b/")) p = p.substring(2);
                inCfg = Paths.get(p.replace('\\', '/')).getFileName().toString().equals(want);
            } else if (inCfg && (line.startsWith("@@") || line.startsWith("+") || line.startsWith(" "))) {
                String content = line.length() > 1 ? line.substring(1) : "";
                Matcher m;
                if ((m = field.matcher(content)).find()) {
                    for (String f : m.group(1).split(",")) {
                        String t = f.trim();
                        if (!t.isEmpty()) ents.add(new ConfigEntity(CfgKind.FIELD, t));
                    }
                }
                if ((m = form.matcher(content)).find()) ents.add(new ConfigEntity(CfgKind.FORM, m.group(1)));
                if ((m = namemap.matcher(content)).find()) ents.add(new ConfigEntity(CfgKind.NAMEMAP, m.group(1)));
                else if ((m = namemap2.matcher(content)).find()) ents.add(new ConfigEntity(CfgKind.NAMEMAP, m.group(2)));
                if ((m = step.matcher(content)).find()) ents.add(new ConfigEntity(CfgKind.STEP, m.group(1)));
                if ((m = schema.matcher(content)).find()) ents.add(new ConfigEntity(CfgKind.METADATA, m.group(1).trim()));
                if ((m = element.matcher(content)).find()) ents.add(new ConfigEntity(CfgKind.METADATA, m.group(1).trim()));
                if ((m = qualifier.matcher(content)).find()) ents.add(new ConfigEntity(CfgKind.METADATA, m.group(1).trim()));
            }
        }
        return ents;
    }

    private static int[] methodLines(Path classesDir, String fqcn, String method) {
        Path cf = classesDir.resolve(fqcn.replace('.', '/') + ".class");
        if (!Files.exists(cf)) return null;
        try {
            byte[] b = Files.readAllBytes(cf);
            ClassReader r = new ClassReader(b);
            int[] res = {-1, -1};
            r.accept(new ClassVisitor(Opcodes.ASM9) {
                public MethodVisitor visitMethod(int access, String name, String desc, String sig, String[] ex) {
                    if (!name.equals(method)) return null;
                    return new MethodVisitor(Opcodes.ASM9) {
                        public void visitLineNumber(int ln, Label label) {
                            if (res[0] < 0) res[0] = ln;
                            if (ln > res[1]) res[1] = ln;
                        }
                    };
                }
            }, 0);
            return res[0] < 0 ? null : res;
        } catch (Exception e) {
            return null;
        }
    }

    private static Set<Integer> linesRange(int a, int b) {
        Set<Integer> s = new TreeSet<>();
        for (int l = a; l <= b; l++) s.add(l);
        return s;
    }

    // -------------------------------------------------------------- aggregate

    private static void aggregateCmd(Map<String, String> opts) throws Exception {
        List<Path> dbs = new ArrayList<>();
        for (Map.Entry<String, String> e : opts.entrySet()) {
            if (e.getKey().equals("db") || e.getKey().matches("db[2-9]|db[1-9][0-9]+")) {
                dbs.add(Paths.get(e.getValue()));
            }
        }
        if (dbs.isEmpty()) dbs.add(Paths.get(require(opts, "db")));
        Path out = Paths.get(require(opts, "out"));
        Files.createDirectories(out.getParent());

        Map<String, Set<String>> impact = new HashMap<>();
        Map<String, Set<String>> covers = new HashMap<>();
        Map<String, Set<String>> refs = new HashMap<>();
        List<String[]> propRefs = new ArrayList<>();
        List<String[]> beanRefs = new ArrayList<>();
        List<String[]> configKeys = new ArrayList<>();
        List<String[]> beanDecls = new ArrayList<>();
        List<String[]> configConsumers = new ArrayList<>();

        Class.forName("org.sqlite.JDBC");
        for (Path db : dbs) {
            try (Connection c = DriverManager.getConnection("jdbc:sqlite:" + db)) {
                mergeMap(c, "SELECT class, test FROM impact", impact);
                mergeMap(c, "SELECT test, class FROM test_covers", covers);
                mergeMap(c, "SELECT from_c, to_c FROM class_refs", refs);
                propRefs.addAll(readDb(c, "SELECT from_c, key, kind FROM property_refs"));
                beanRefs.addAll(readDb(c, "SELECT from_c, ref, kind FROM bean_refs"));
                configKeys.addAll(readDb(c, "SELECT file, key FROM config_keys"));
                beanDecls.addAll(readDb(c, "SELECT file, bean_type, bean_id FROM bean_decls"));
                configConsumers.addAll(readDb(c, "SELECT file, class FROM config_consumers"));
            }
        }

        Map<String, Set<String>> propImpact = new HashMap<>();
        for (String[] pr : propRefs) {
            Set<String> tests = impact.get(topLevel(pr[0]));
            if (tests != null) propImpact.computeIfAbsent(pr[1], k -> new HashSet<>()).addAll(tests);
        }

        try (Connection c = DriverManager.getConnection("jdbc:sqlite:" + out)) {
            c.setAutoCommit(false);
            String[] drops = {"class_refs", "test_covers", "impact",
                    "property_refs", "bean_refs", "config_keys", "bean_decls", "property_impact",
                    "config_consumers"};
            for (String t : drops) c.createStatement().execute("DROP TABLE IF EXISTS " + t);
            c.createStatement().execute("CREATE TABLE class_refs(from_c TEXT, to_c TEXT, kind TEXT)");
            c.createStatement().execute("CREATE TABLE test_covers(test TEXT, class TEXT)");
            c.createStatement().execute("CREATE TABLE impact(class TEXT, test TEXT)");
            c.createStatement().execute("CREATE TABLE property_refs(from_c TEXT, key TEXT, kind TEXT)");
            c.createStatement().execute("CREATE TABLE bean_refs(from_c TEXT, ref TEXT, kind TEXT)");
            c.createStatement().execute("CREATE TABLE config_keys(file TEXT, key TEXT)");
            c.createStatement().execute("CREATE TABLE bean_decls(file TEXT, bean_type TEXT, bean_id TEXT)");
            c.createStatement().execute("CREATE TABLE property_impact(key TEXT, test TEXT)");
            c.createStatement().execute("CREATE TABLE config_consumers(file TEXT, class TEXT)");
            try (PreparedStatement ps1 = c.prepareStatement("INSERT INTO class_refs VALUES (?,?,?)");
                 PreparedStatement ps2 = c.prepareStatement("INSERT INTO test_covers VALUES (?,?)");
                 PreparedStatement ps3 = c.prepareStatement("INSERT INTO impact VALUES (?,?)");
                 PreparedStatement ps4 = c.prepareStatement("INSERT INTO property_refs VALUES (?,?,?)");
                 PreparedStatement ps5 = c.prepareStatement("INSERT INTO bean_refs VALUES (?,?,?)");
                 PreparedStatement ps6 = c.prepareStatement("INSERT INTO config_keys VALUES (?,?)");
                 PreparedStatement ps7 = c.prepareStatement("INSERT INTO bean_decls VALUES (?,?,?)");
                 PreparedStatement ps8 = c.prepareStatement("INSERT INTO property_impact VALUES (?,?)");
                 PreparedStatement ps9 = c.prepareStatement("INSERT INTO config_consumers VALUES (?,?)")) {
                for (Map.Entry<String, Set<String>> e : refs.entrySet())
                    for (String to : e.getValue()) { ps1.setString(1, e.getKey()); ps1.setString(2, to); ps1.setString(3, "reference"); ps1.addBatch(); }
                for (Map.Entry<String, Set<String>> e : covers.entrySet())
                    for (String cls : e.getValue()) { ps2.setString(1, e.getKey()); ps2.setString(2, cls); ps2.addBatch(); }
                for (Map.Entry<String, Set<String>> e : impact.entrySet())
                    for (String t : e.getValue()) { ps3.setString(1, e.getKey()); ps3.setString(2, t); ps3.addBatch(); }
                for (String[] r : propRefs) { ps4.setString(1, r[0]); ps4.setString(2, r[1]); ps4.setString(3, r[2]); ps4.addBatch(); }
                for (String[] r : beanRefs) { ps5.setString(1, r[0]); ps5.setString(2, r[1]); ps5.setString(3, r[2]); ps5.addBatch(); }
                for (String[] r : configKeys) { ps6.setString(1, r[0]); ps6.setString(2, r[1]); ps6.addBatch(); }
                for (String[] r : beanDecls) { ps7.setString(1, r[0]); ps7.setString(2, r[1]); ps7.setString(3, r.length > 2 ? r[2] : ""); ps7.addBatch(); }
                for (Map.Entry<String, Set<String>> e : propImpact.entrySet())
                    for (String t : e.getValue()) { ps8.setString(1, e.getKey()); ps8.setString(2, t); ps8.addBatch(); }
                for (String[] r : configConsumers) { ps9.setString(1, r[0]); ps9.setString(2, r[1]); ps9.addBatch(); }
                ps1.executeBatch(); ps2.executeBatch(); ps3.executeBatch();
                ps4.executeBatch(); ps5.executeBatch(); ps6.executeBatch();
                ps7.executeBatch(); ps8.executeBatch(); ps9.executeBatch();
            }
            c.commit();
        }
        System.out.println("aggregate: " + dbs.size() + " module indexes -> " + out
                + " (" + impact.size() + " impacted classes, " + propImpact.size() + " impacted properties)");
    }

    private static void mergeMap(Connection c, String sql, Map<String, Set<String>> dst) throws Exception {
        try (PreparedStatement ps = c.prepareStatement(sql);
             ResultSet rs = ps.executeQuery()) {
            while (rs.next()) {
                dst.computeIfAbsent(rs.getString(1), k -> new HashSet<>()).add(rs.getString(2));
            }
        }
    }

    private static List<String[]> readDb(Connection c, String sql) throws Exception {
        List<String[]> out = new ArrayList<>();
        try (PreparedStatement ps = c.prepareStatement(sql);
             ResultSet rs = ps.executeQuery()) {
            int n = rs.getMetaData().getColumnCount();
            while (rs.next()) {
                String[] row = new String[n];
                for (int i = 0; i < n; i++) row[i] = rs.getString(i + 1);
                out.add(row);
            }
        }
        return out;
    }

    // ---------------------------------------------------------------- validate

    private static void validateCmd(Map<String, String> opts) throws Exception {
        String moduleArg = opts.get("module");
        Path perTest = Paths.get(opts.getOrDefault("per-test",
                moduleArg != null ? Paths.get(moduleArg).resolve("target/per-test").toString()
                                  : "target/per-test"));
        Path db = Paths.get(opts.getOrDefault("db",
                moduleArg != null ? Paths.get(moduleArg).resolve("target/test-graph/impact-index.sqlite").toString()
                                  : "impact-index.sqlite"));

        // 1) at least one non-empty per-test exec
        long execCount = 0;
        if (Files.exists(perTest)) {
            try (var stream = Files.walk(perTest)) {
                execCount = stream.filter(f -> f.toString().endsWith(".exec") && sizeOf(f) > 0).count();
            }
        }
        if (execCount == 0) {
            System.out.println("warn: no per-test .exec files in " + perTest
                    + " (ok for a merged root index; skipping exec check)");
        }

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
            long propRefs = count(c, "SELECT COUNT(*) FROM property_refs");
            long beanRefs = count(c, "SELECT COUNT(*) FROM bean_refs");
            long configKeys = count(c, "SELECT COUNT(*) FROM config_keys");
            long beanDecls = count(c, "SELECT COUNT(*) FROM bean_decls");
            long propImpacts = count(c, "SELECT COUNT(*) FROM property_impact");

            if (propRefs == 0) fail("property_refs is empty");
            if (configKeys == 0) fail("config_keys is empty");
            if (beanDecls == 0) fail("bean_decls is empty");

            System.out.println("validate OK: " + execCount + " exec files, " + covers
                    + " test_covers rows, " + edges + " edges, " + impacts + " impact rows");
            System.out.println("  config: " + propRefs + " property refs, " + beanRefs
                    + " bean refs, " + configKeys + " config keys, " + beanDecls
                    + " bean decls, " + propImpacts + " property_impact rows");
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

    private static String javaSourceToFqcn(Path file) {
        String s = file.toString();
        String markerMain = "src" + File.separator + "main" + File.separator + "java";
        String markerTest = "src" + File.separator + "test" + File.separator + "java";
        int i = s.indexOf(markerMain);
        if (i >= 0) return toFqcn(s.substring(i + markerMain.length() + 1));
        int j = s.indexOf(markerTest);
        if (j >= 0) return toFqcn(s.substring(j + markerTest.length() + 1));
        return null;
    }

    private static String pathToFqcn(String path) {
        String s = Paths.get(path).toString();
        String markerMain = "src" + File.separator + "main" + File.separator + "java";
        String markerTest = "src" + File.separator + "test" + File.separator + "java";
        int i = s.indexOf(markerMain);
        if (i >= 0) return toFqcn(s.substring(i + markerMain.length() + 1));
        int j = s.indexOf(markerTest);
        if (j >= 0) return toFqcn(s.substring(j + markerTest.length() + 1));
        if (!s.endsWith(".java") && !s.contains(File.separator) && !s.contains("/")
                && s.contains(".")) return s; // already an fqcn (no path separators)
        return null;
    }

    private static String toFqcn(String rel) {
        if (rel.endsWith(".java")) rel = rel.substring(0, rel.length() - 5);
        return rel.replace(File.separatorChar, '.').replace('/', '.');
    }

    private static void writeTsv(Path file, List<String[]> rows) throws IOException {
        StringBuilder sb = new StringBuilder();
        for (String[] r : rows) {
            sb.append(String.join("\t", r)).append('\n');
        }
        Files.writeString(file, sb.toString());
    }

    private static List<String[]> readTsv(Path file) throws IOException {
        List<String[]> rows = new ArrayList<>();
        if (!Files.exists(file)) return rows;
        for (String line : Files.readAllLines(file)) {
            if (line.isEmpty()) continue;
            rows.add(line.split("\t", -1));
        }
        return rows;
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
            if (a.startsWith("--")) {
                if (i + 1 < args.length && !args[i + 1].startsWith("--")) {
                    m.put(a.substring(2), args[++i]);
                } else {
                    m.put(a.substring(2), ""); // boolean flag
                }
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
        System.out.println("  static      --module <dir> [--out edges.tsv]");
        System.out.println("  config      --module <dir> [--out dir] [--root <repo>]");
        System.out.println("  build       --module <dir> [--per-test dir] [--edges file] [--config dir] [--db file]");
        System.out.println("  impacted    --db <file> (--file <src|fqcn> | --property <key> |");
        System.out.println("                          --configfile <path> | --bean <type|id> | --beanfile <path>)");
        System.out.println("  refine      --db <file> --per-test <dir> --classes <dir> (--diff <file|-> | --base <ref> [--head <ref>])");
        System.out.println("  validate    --module <dir> [--per-test dir] [--db file]");
        System.out.println("  aggregate   --out <file> --db <m1> [--db2 <m2> ...]");
    }

    private static final class Ref {
        final String to;
        final String kind;
        Ref(String to, String kind) { this.to = to; this.kind = kind; }
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            usage();
            System.exit(2);
        }
        Map<String, String> opts = parseArgs(args, 1);
        switch (args[0]) {
            case "static":   staticCmd(opts); break;
            case "config":   configCmd(opts); break;
            case "build":    buildCmd(opts); break;
            case "refine":   refineCmd(opts); break;
            case "impacted": impactedCmd(opts); break;
            case "validate": validateCmd(opts); break;
            case "aggregate": aggregateCmd(opts); break;
            default:
                usage();
                System.exit(2);
        }
    }
}
