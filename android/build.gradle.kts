import org.gradle.api.tasks.compile.JavaCompile
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    if (project.name != "app") {
        afterEvaluate {
            val androidExt = extensions.findByName("android")
            if (androidExt != null) {
                val setter = androidExt.javaClass.methods.firstOrNull {
                    it.name == "setCompileSdkVersion" &&
                        it.parameterCount == 1 &&
                        it.parameterTypes[0] == Int::class.javaPrimitiveType
                } ?: androidExt.javaClass.methods.firstOrNull {
                    it.name == "setCompileSdk" && it.parameterCount == 1
                }
                try {
                    setter?.invoke(androidExt, 36)
                } catch (e: Exception) {
                    println("compileSdk override skipped for ${project.name}: $e")
                }
            }
        }
    }
}

subprojects {
    if (project.name != "app") {
        afterEvaluate {
            val androidExt = extensions.findByName("android")
            if (androidExt != null) {
                try {
                    val lint = androidExt.javaClass.methods.firstOrNull {
                        it.name == "getLint" && it.parameterCount == 0
                    }?.invoke(androidExt)
                    if (lint != null) {
                        lint.javaClass.methods.firstOrNull { it.name == "setCheckReleaseBuilds" }
                            ?.invoke(lint, false)
                        lint.javaClass.methods.firstOrNull { it.name == "setAbortOnError" }
                            ?.invoke(lint, false)
                    }
                } catch (e: Exception) {
                    println("lint override skipped for ${project.name}: $e")
                }
                try {
                    val co = androidExt.javaClass.methods.firstOrNull {
                        it.name == "getCompileOptions" && it.parameterCount == 0
                    }?.invoke(androidExt)
                    if (co != null) {
                        co.javaClass.methods.firstOrNull { it.name == "setSourceCompatibility" }
                            ?.invoke(co, JavaVersion.VERSION_17)
                        co.javaClass.methods.firstOrNull { it.name == "setTargetCompatibility" }
                            ?.invoke(co, JavaVersion.VERSION_17)
                    }
                } catch (e: Exception) {
                    println("compileOptions override skipped for ${project.name}: $e")
                }
            }
            tasks.withType(JavaCompile::class.java).configureEach {
                sourceCompatibility = JavaVersion.VERSION_17.toString()
                targetCompatibility = JavaVersion.VERSION_17.toString()
            }
            tasks.withType(KotlinCompile::class.java).configureEach {
                compilerOptions.jvmTarget.set(JvmTarget.JVM_17)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
