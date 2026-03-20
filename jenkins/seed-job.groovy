// Jenkins Seed Job - Creates all Vault cluster pipeline jobs
//
// This is a Job DSL script. Configure a freestyle job in Jenkins that:
// 1. Has the Job DSL plugin installed
// 2. Points to this file via "Process Job DSLs" build step
// 3. SCM: your vault-cluster repository
//
// It creates the following jobs:
//   vault-cluster/
//     nonprod-test/
//       plan, apply, launch-node, terminate-node, rolling-update,
//       cluster-status, backup-restore, setup-backup-auth
//     nonprod/
//       plan, apply, launch-node, terminate-node, rolling-update,
//       cluster-status, backup-restore, sync-to-nonprod-test,
//       store-credentials
//     prod/
//       plan, apply, launch-node, terminate-node, rolling-update,
//       cluster-status, backup-restore, store-credentials
//     migration/
//       migrate-nonprod, migrate-prod
//     rekey-recovery

// Environment configuration
// Vault tokens are fetched from AWS Secrets Manager at runtime (not stored in Jenkins).
// AWS auth is handled by the withAwsAuth shared library step:
//   - nonprod/nonprod-test: Jenkins node instance profile (no credentials needed)
//   - prod: assumes 'jenkins' role in prod account via STS
def environments = [
    'nonprod-test': [
        vaultAddr: 'https://vault.nonprod-test.reisys.io',
        clusterName: 'vault-nonprod-test',
    ],
    'nonprod': [
        vaultAddr: 'https://vault.nonprod.reisys.io',
        clusterName: 'vault-nonprod',
    ],
    'prod': [
        vaultAddr: 'https://vault.prod.reisys.io',
        clusterName: 'vault-prod',
    ],
]

def repoUrl = 'https://github.com/your-org/vault-cluster.git'
def repoBranch = 'main'

// Create folder structure
folder('vault-cluster') {
    description('Vault Cluster Management Jobs')
}

environments.each { envName, envConfig ->
    folder("vault-cluster/${envName}") {
        description("Vault cluster jobs for ${envName}")
    }

    // =========================================================================
    // Plan
    // =========================================================================
    pipelineJob("vault-cluster/${envName}/plan") {
        description("Run tofu plan for ${envName}")
        parameters {
            stringParam('TARGET', '', 'Optional: -target=module.xxx (leave empty for full plan)')
        }
        definition {
            cpsScm {
                scm {
                    git {
                        remote { url(repoUrl) }
                        branches(repoBranch)
                    }
                }
                scriptPath('jenkins/pipelines/plan.Jenkinsfile')
            }
        }
    }

    // =========================================================================
    // Apply
    // =========================================================================
    pipelineJob("vault-cluster/${envName}/apply") {
        description("Run tofu apply for ${envName}")
        parameters {
            stringParam('TARGET', '', 'Optional: -target=module.xxx (leave empty for full apply)')
            booleanParam('AUTO_APPROVE', false, 'Skip interactive approval (use with caution)')
        }
        definition {
            cpsScm {
                scm {
                    git {
                        remote { url(repoUrl) }
                        branches(repoBranch)
                    }
                }
                scriptPath('jenkins/pipelines/apply.Jenkinsfile')
            }
        }
    }

    // =========================================================================
    // Launch Node
    // =========================================================================
    pipelineJob("vault-cluster/${envName}/launch-node") {
        description("Launch a Vault node in ${envName}")
        parameters {
            choiceParam('AZ_INDEX', ['0', '1', '2'], 'Availability zone index')
        }
        definition {
            cpsScm {
                scm {
                    git {
                        remote { url(repoUrl) }
                        branches(repoBranch)
                    }
                }
                scriptPath('jenkins/pipelines/launch-node.Jenkinsfile')
            }
        }
    }

    // =========================================================================
    // Terminate Node
    // =========================================================================
    pipelineJob("vault-cluster/${envName}/terminate-node") {
        description("Terminate a Vault node in ${envName}")
        parameters {
            stringParam('INSTANCE_ID', '', 'EC2 instance ID to terminate (e.g., i-0abc123)')
            booleanParam('REMOVE_FROM_RAFT', false, 'Permanently remove from Raft cluster')
        }
        definition {
            cpsScm {
                scm {
                    git {
                        remote { url(repoUrl) }
                        branches(repoBranch)
                    }
                }
                scriptPath('jenkins/pipelines/terminate-node.Jenkinsfile')
            }
        }
    }

    // =========================================================================
    // Rolling Update
    // =========================================================================
    pipelineJob("vault-cluster/${envName}/rolling-update") {
        description("Rolling update all Vault nodes in ${envName}")
        parameters {
            booleanParam('SKIP_TERRAFORM', false, 'Skip tofu apply (node replacement only)')
        }
        definition {
            cpsScm {
                scm {
                    git {
                        remote { url(repoUrl) }
                        branches(repoBranch)
                    }
                }
                scriptPath('jenkins/pipelines/rolling-update.Jenkinsfile')
            }
        }
    }

    // =========================================================================
    // Cluster Status
    // =========================================================================
    pipelineJob("vault-cluster/${envName}/cluster-status") {
        description("Check Vault cluster health for ${envName}")
        definition {
            cpsScm {
                scm {
                    git {
                        remote { url(repoUrl) }
                        branches(repoBranch)
                    }
                }
                scriptPath('jenkins/pipelines/cluster-status.Jenkinsfile')
            }
        }
    }

    // =========================================================================
    // Backup / Restore
    // =========================================================================
    pipelineJob("vault-cluster/${envName}/backup-restore") {
        description("Backup or restore Vault data for ${envName}")
        parameters {
            choiceParam('ACTION', ['backup', 'restore', 'list'], 'Action to perform')
            stringParam('S3_KEY', '', 'S3 key for restore (leave empty to list available snapshots)')
        }
        definition {
            cpsScm {
                scm {
                    git {
                        remote { url(repoUrl) }
                        branches(repoBranch)
                    }
                }
                scriptPath('jenkins/pipelines/backup-restore.Jenkinsfile')
            }
        }
    }

    // =========================================================================
    // Setup Backup Auth (one-time per environment)
    // =========================================================================
    pipelineJob("vault-cluster/${envName}/setup-backup-auth") {
        description("One-time setup: configure Vault AWS IAM auth for automated backups in ${envName}")
        definition {
            cpsScm {
                scm {
                    git {
                        remote { url(repoUrl) }
                        branches(repoBranch)
                    }
                }
                scriptPath('jenkins/pipelines/setup-backup-auth.Jenkinsfile')
            }
        }
    }

    // =========================================================================
    // Store Credentials (nonprod + prod only)
    // =========================================================================
    if (envName != 'nonprod-test') {
        pipelineJob("vault-cluster/${envName}/store-credentials") {
            description("Store Vault root token and recovery keys in Secrets Manager for ${envName}")
            parameters {
                passwordParam('ROOT_TOKEN', '', 'Vault root token')
                passwordParam('RECOVERY_KEY_1', '', 'Recovery key 1')
                passwordParam('RECOVERY_KEY_2', '', 'Recovery key 2')
                passwordParam('RECOVERY_KEY_3', '', 'Recovery key 3')
                passwordParam('RECOVERY_KEY_4', '', 'Recovery key 4')
                passwordParam('RECOVERY_KEY_5', '', 'Recovery key 5')
            }
            definition {
                cpsScm {
                    scm {
                        git {
                            remote { url(repoUrl) }
                            branches(repoBranch)
                        }
                    }
                    scriptPath('jenkins/pipelines/store-credentials.Jenkinsfile')
                }
            }
        }
    }
}

// =========================================================================
// Sync nonprod -> nonprod-test
// =========================================================================
pipelineJob("vault-cluster/nonprod/sync-to-nonprod-test") {
    description("Sync Vault data from nonprod to nonprod-test")
    parameters {
        booleanParam('CONFIRM', false, 'Check to confirm you want to overwrite nonprod-test data')
    }
    definition {
        cpsScm {
            scm {
                git {
                    remote { url(repoUrl) }
                    branches(repoBranch)
                }
            }
            scriptPath('jenkins/pipelines/sync-to-nonprod-test.Jenkinsfile')
        }
    }
}

// =========================================================================
// Migration jobs
// =========================================================================
folder('vault-cluster/migration') {
    description('One-time migration jobs for moving legacy clusters')
}

['nonprod', 'prod'].each { envName ->
    def envConfig = environments[envName]

    pipelineJob("vault-cluster/migration/migrate-${envName}") {
        description("Migrate legacy ${envName} Vault cluster to new infrastructure")
        parameters {
            stringParam('LEGACY_VAULT_ADDR', '', 'Address of the legacy Vault cluster')
            passwordParam('LEGACY_VAULT_TOKEN', '', 'Root token for legacy cluster')
            booleanParam('SKIP_INFRA_DEPLOY', false, 'Skip tofu apply (infra already deployed)')
        }
        definition {
            cpsScm {
                scm {
                    git {
                        remote { url(repoUrl) }
                        branches(repoBranch)
                    }
                }
                scriptPath('jenkins/pipelines/migrate.Jenkinsfile')
            }
        }
    }
}

// =========================================================================
// Rekey Recovery
// =========================================================================
pipelineJob("vault-cluster/rekey-recovery") {
    description("Regenerate lost recovery keys (requires root token)")
    parameters {
        choiceParam('ENVIRONMENT', ['nonprod-test', 'nonprod', 'prod'], 'Target environment')
    }
    definition {
        cpsScm {
            scm {
                git {
                    remote { url(repoUrl) }
                    branches(repoBranch)
                }
            }
            scriptPath('jenkins/pipelines/rekey-recovery.Jenkinsfile')
        }
    }
}

// =============================================================================
// Views
// =============================================================================

// Top-level dashboard view showing all environments at a glance
nestedView('Vault Cluster') {
    description('Vault HA Cluster - All Environments')

    views {
        // Per-environment list views
        environments.each { envName, envConfig ->
            listView(envName) {
                description("Vault cluster jobs for ${envName} (${envConfig.vaultAddr})")
                jobs {
                    regex("vault-cluster/${envName}/.*")
                }
                columns {
                    status()
                    weather()
                    name()
                    lastSuccess()
                    lastFailure()
                    lastDuration()
                    buildButton()
                }
            }
        }

        // Migration view
        listView('Migration') {
            description('One-time migration jobs for legacy clusters')
            jobs {
                regex('vault-cluster/migration/.*')
            }
            columns {
                status()
                weather()
                name()
                lastSuccess()
                lastFailure()
                lastDuration()
                buildButton()
            }
        }

        // Cross-cutting view: all health checks
        listView('Health Checks') {
            description('Cluster status across all environments')
            jobs {
                name('vault-cluster/nonprod-test/cluster-status')
                name('vault-cluster/nonprod/cluster-status')
                name('vault-cluster/prod/cluster-status')
            }
            columns {
                status()
                weather()
                name()
                lastSuccess()
                lastFailure()
                lastDuration()
                buildButton()
            }
        }

        // Cross-cutting view: all backup/restore jobs
        listView('Backups') {
            description('Backup and restore jobs across all environments')
            jobs {
                name('vault-cluster/nonprod-test/backup-restore')
                name('vault-cluster/nonprod/backup-restore')
                name('vault-cluster/prod/backup-restore')
                name('vault-cluster/nonprod/sync-to-nonprod-test')
            }
            columns {
                status()
                weather()
                name()
                lastSuccess()
                lastFailure()
                lastDuration()
                buildButton()
            }
        }

        // Cross-cutting view: infrastructure (plan/apply)
        listView('Infrastructure') {
            description('Terraform plan/apply across all environments')
            jobs {
                name('vault-cluster/nonprod-test/plan')
                name('vault-cluster/nonprod-test/apply')
                name('vault-cluster/nonprod/plan')
                name('vault-cluster/nonprod/apply')
                name('vault-cluster/prod/plan')
                name('vault-cluster/prod/apply')
            }
            columns {
                status()
                weather()
                name()
                lastSuccess()
                lastFailure()
                lastDuration()
                buildButton()
            }
        }
    }
}

// Sectioned view inside the vault-cluster folder for a single-page overview
dashboardView('vault-cluster/Dashboard') {
    description('Vault Cluster Overview - All Environments')
    jobs {
        regex('vault-cluster/.*')
    }
    columns {
        status()
        weather()
        name()
        lastSuccess()
        lastFailure()
        lastDuration()
        buildButton()
    }
    topPortlets {
        jenkinsJobsList {
            displayName('nonprod-test')
            regex('vault-cluster/nonprod-test/.*')
        }
        jenkinsJobsList {
            displayName('nonprod')
            regex('vault-cluster/nonprod/.*')
        }
        jenkinsJobsList {
            displayName('prod')
            regex('vault-cluster/prod/.*')
        }
    }
    bottomPortlets {
        jenkinsJobsList {
            displayName('Migration & Utilities')
            regex('vault-cluster/(migration|rekey).*')
        }
    }
}
