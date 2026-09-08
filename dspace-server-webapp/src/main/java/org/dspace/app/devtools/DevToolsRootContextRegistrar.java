package org.dspace.app.devtools;

import java.lang.reflect.Field;
import java.util.List;

import org.springframework.boot.context.event.ApplicationPreparedEvent;
import org.springframework.context.ApplicationListener;
import org.springframework.context.ConfigurableApplicationContext;

/**
 * Registers each application context with the current DevTools Restarter.
 *
 * DevTools only tracks "root" contexts: Restarter.prepare() skips any context
 * that has a parent. DSpace's web context always has a parent (the kernel's
 * service-manager context installed by DSpaceKernelInitializer), so without
 * this listener the Restarter's rootContexts list stays empty and restart()
 * never closes the previous generation. The old Tomcat keeps holding the
 * server port until the next generation fails with "Address already in use".
 *
 * Adding the context directly to rootContexts bypasses the parent check, so
 * every generation is closed before the next one starts. Each world loads its
 * own Restarter copy, and this listener is re-invoked in every world, so the
 * registration repairs itself across restarts. Non-DevTools launches see an
 * app classloader and do nothing.
 */
public class DevToolsRootContextRegistrar implements ApplicationListener<ApplicationPreparedEvent> {

    @Override
    public void onApplicationEvent(ApplicationPreparedEvent event) {
        try {
            ClassLoader tccl = Thread.currentThread().getContextClassLoader();
            if (!"org.springframework.boot.devtools.restart.classloader.RestartClassLoader"
                .equals(tccl.getClass().getName())) {
                return;
            }
            Class<?> restarterClass = Class.forName(
                "org.springframework.boot.devtools.restart.Restarter", false, tccl);
            Object restarter = restarterClass.getMethod("getInstance").invoke(null);
            if (restarter == null) {
                return;
            }
            ConfigurableApplicationContext context = event.getApplicationContext();
            Field field = restarterClass.getDeclaredField("rootContexts");
            field.setAccessible(true);
            @SuppressWarnings("unchecked")
            List<ConfigurableApplicationContext> contexts =
                (List<ConfigurableApplicationContext>) field.get(restarter);
            if (!contexts.contains(context)) {
                contexts.add(context);
            }
        }
        catch (Throwable t) {
            // Never break startup; DevTools context tracking is best-effort.
        }
    }

}
