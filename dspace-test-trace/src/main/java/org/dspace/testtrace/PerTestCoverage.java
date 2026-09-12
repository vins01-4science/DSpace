/**
 * The contents of this file are subject to the license and copyright
 * detailed in the LICENSE and NOTICE files at the root of the source
 * tree and available online at
 *
 * http://www.dspace.org/license/
 */
package org.dspace.testtrace;

import java.io.File;
import java.io.FileOutputStream;
import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

import javax.management.MBeanServer;
import javax.management.ObjectName;

import org.junit.platform.engine.TestDescriptor;
import org.junit.platform.engine.TestExecutionResult;
import org.junit.platform.engine.TestSource;
import org.junit.platform.engine.support.descriptor.ClassSource;
import org.junit.platform.engine.support.descriptor.MethodSource;
import org.junit.platform.launcher.TestExecutionListener;
import org.junit.platform.launcher.TestIdentifier;
import org.junit.platform.launcher.TestPlan;

/**
 * JUnit Platform {@link TestExecutionListener} that captures per-test code coverage.
 *
 * <p>It talks to the JaCoCo runtime agent through its JMX MBean
 * ({@code org.jacoco:type=Runtime}, interface {@code org.jacoco.agent.rt.IAgent}).
 * After every test method it requests the current execution data (which also resets
 * the agent) and writes it to {@code target/per-test/<Class>.<method>.exec}.</p>
 *
 * <p>Because DSpace runs JUnit 4 tests through the JUnit Vintage engine on top of the
 * JUnit Platform, a single listener registered via the
 * {@code META-INF/services/org.junit.platform.launcher.TestExecutionListener} SPI
 * covers both JUnit 5 and JUnit 4 tests.</p>
 *
 * <p>If the JaCoCo agent is not attached (e.g. the {@code test-class-graph} profile is
 * not active) the listener degrades to a no-op.</p>
 */
public class PerTestCoverage implements TestExecutionListener {

    private static final String MBEAN_NAME = "org.jacoco:type=Runtime";
    private static final Path OUT_DIR = Paths.get("target", "per-test");

    private final ObjectName objectName;
    private final MBeanServer server;

    public PerTestCoverage() {
        ObjectName name = null;
        MBeanServer mbeanServer = null;
        try {
            name = new ObjectName(MBEAN_NAME);
            mbeanServer = ManagementFactory.getPlatformMBeanServer();
            if (!mbeanServer.isRegistered(name)) {
                name = null;
                mbeanServer = null;
            }
        } catch (Exception ignored) {
            name = null;
            mbeanServer = null;
        }
        this.objectName = name;
        this.server = mbeanServer;
    }

    @Override
    public void testPlanExecutionStarted(TestPlan testPlan) {
        reset();
    }

    @Override
    public void executionFinished(TestIdentifier testIdentifier, TestExecutionResult testExecutionResult) {
        if (testIdentifier.getType() != TestDescriptor.Type.TEST) {
            return;
        }
        if (objectName == null || server == null) {
            return;
        }
        try {
            byte[] data = (byte[]) server.invoke(objectName, "getExecutionData",
                    new Object[] { Boolean.TRUE }, new String[] { "boolean" });
            if (data != null && data.length > 0) {
                write(data, testIdentifier);
            }
        } catch (Exception ignored) {
            // best-effort coverage capture; never fail the test run because of it
        }
    }

    private void reset() {
        if (objectName == null || server == null) {
            return;
        }
        try {
            server.invoke(objectName, "reset", new Object[0], new String[0]);
        } catch (Exception ignored) {
            // ignore
        }
    }

    private void write(byte[] data, TestIdentifier testIdentifier) throws Exception {
        String className = "unknown";
        String methodName = "test";
        TestSource source = testIdentifier.getSource().orElse(null);
        if (source instanceof MethodSource methodSource) {
            className = methodSource.getClassName();
            methodName = methodSource.getMethodName();
        } else if (source instanceof ClassSource classSource) {
            className = classSource.getClassName();
        }
        Files.createDirectories(OUT_DIR);
        String safe = (className + "." + methodName).replaceAll("[^a-zA-Z0-9._-]", "_");
        File out = OUT_DIR.resolve(safe + ".exec").toFile();
        try (FileOutputStream fos = new FileOutputStream(out)) {
            fos.write(data);
        }
    }
}
