package org.dspace.app.devtools;

import java.lang.reflect.Field;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.Arrays;
import java.util.Set;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.env.EnvironmentPostProcessor;
import org.springframework.core.Ordered;
import org.springframework.core.env.ConfigurableEnvironment;

/**
 * Repairs the Spring Boot DevTools Restarter in the "restartedMain" world.
 *
 * When DevTools relaunches the application on the restartedMain thread with a
 * RestartClassLoader, the devtools listener that runs in that world creates a
 * second Restarter. Because thread "restartedMain" is not "main",
 * DefaultRestartInitializer returns no URLs, leaving that per-world Restarter
 * with a null initialUrls field. The @ConditionalOnInitializedRestarter gate on
 * LocalDevToolsAutoConfiguration then skips the ClassPathFileSystemWatcher
 * entirely, so classpath changes never trigger a restart.
 *
 * This EnvironmentPostProcessor runs before auto-configuration in every world
 * and seeds the current world's Restarter with the URLs of its own
 * RestartClassLoader. It fills both the initialUrls field (checked by the
 * condition) and the urls set (used to build the next generation's
 * RestartClassLoader). Restarts of restarts therefore keep working.
 *
 * In a non-DevTools launch the thread context classloader is the app loader, so
 * this class does nothing.
 */
public class DevToolsRestarterUrlSeeder implements EnvironmentPostProcessor, Ordered {

    @Override
    public int getOrder() {
        return HIGHEST_PRECEDENCE;
    }

    @Override
    public void postProcessEnvironment(ConfigurableEnvironment environment, SpringApplication application) {
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
            URL[] urls = ((URLClassLoader) tccl).getURLs();
            Field initialUrlsField = restarterClass.getDeclaredField("initialUrls");
            initialUrlsField.setAccessible(true);
            if (initialUrlsField.get(restarter) == null) {
                initialUrlsField.set(restarter, urls);
            }
            Field urlsField = restarterClass.getDeclaredField("urls");
            urlsField.setAccessible(true);
            @SuppressWarnings("unchecked")
            Set<URL> urlSet = (Set<URL>) urlsField.get(restarter);
            urlSet.addAll(Arrays.asList(urls));
        }
        catch (Throwable t) {
            // Never break startup; DevTools seeding is best-effort.
        }
    }

}
