// Vault Cluster - Backup and Restore (scripted pipeline)
// Vault token fetched from AWS Secrets Manager at runtime.

def envName = env.JOB_NAME.split('/')[1]
def clusterName = "vault-${envName}"

properties([
    parameters([
        choice(name: 'ACTION', choices: ['backup', 'restore', 'list'], description: 'Action to perform'),
        string(name: 'S3_KEY', defaultValue: '', description: 'S3 key for restore (leave empty to list available snapshots)')
    ])
])

node {
    timestamps {
        ansiColor('xterm') {
            try {
                stage('Checkout') {
                    checkout scm
                }

                def img = buildVaultOpsImage()

                def vaultAddr = ''
                withAwsAuth(envName, img) {
                    vaultAddr = sh(
                        script: "aws ssm get-parameter --name /${clusterName}/config/vault-url --query Parameter.Value --output text",
                        returnStdout: true
                    ).trim()
                }

                def fetchToken = """
                    export VAULT_TOKEN=\$(aws secretsmanager get-secret-value \
                        --secret-id ${clusterName}/vault/root-token \
                        --query SecretString --output text | jq -r '.token')
                """.stripIndent().trim()

                // Parse bucket from tfvars
                def backupBucket = sh(
                    script: "grep '^backup_s3_bucket' terraform/environments/${envName}.tfvars | sed 's/.*= *\"\\(.*\\)\"/\\1/'",
                    returnStdout: true
                ).trim()

                echo "Bucket: ${backupBucket}"
                echo "Cluster: ${clusterName}"

                if (params.ACTION == 'list' || (params.ACTION == 'restore' && !params.S3_KEY?.trim())) {
                    stage('List Snapshots') {
                        withAwsAuth(envName, img) {
                            sh """
                                echo "=== Daily snapshots (last 10) ==="
                                aws s3 ls "s3://${backupBucket}/${clusterName}/daily/" --recursive | sort -r | head -10 || echo "(none)"

                                echo ""
                                echo "=== Weekly snapshots (last 5) ==="
                                aws s3 ls "s3://${backupBucket}/${clusterName}/weekly/" --recursive | sort -r | head -5 || echo "(none)"

                                echo ""
                                echo "=== Sync snapshots (last 5) ==="
                                aws s3 ls "s3://${backupBucket}/${clusterName}/sync/" --recursive | sort -r | head -5 || echo "(none)"
                            """
                        }
                    }
                }

                if (params.ACTION == 'backup') {
                    stage('Take Backup') {
                        withAwsAuth(envName, img) {
                            sh """
                                ${fetchToken}

                                TIMESTAMP=\$(date -u +"%Y%m%d-%H%M%S")
                                SNAP_FILE="/tmp/vault-snapshot-\${TIMESTAMP}.snap"

                                VAULT_ADDR=${vaultAddr} vault operator raft snapshot save "\$SNAP_FILE"
                                ls -lh "\$SNAP_FILE"

                                DAILY_KEY="${clusterName}/daily/vault-snapshot-\${TIMESTAMP}.snap"
                                aws s3 cp "\$SNAP_FILE" "s3://${backupBucket}/\${DAILY_KEY}"
                                echo "Uploaded to s3://${backupBucket}/\${DAILY_KEY}"

                                rm -f "\$SNAP_FILE"
                            """
                        }
                    }
                }

                if (params.ACTION == 'restore' && params.S3_KEY?.trim()) {
                    stage('Approve Restore') {
                        input message: "RESTORE ${envName} from s3://${backupBucket}/${params.S3_KEY}? This will REPLACE all current data.", ok: 'RESTORE'
                    }

                    stage('Restore') {
                        withAwsAuth(envName, img) {
                            sh """
                                ${fetchToken}

                                SNAP_FILE="/tmp/vault-restore-\$(date +%s).snap"

                                aws s3 cp "s3://${backupBucket}/${params.S3_KEY}" "\$SNAP_FILE"
                                ls -lh "\$SNAP_FILE"

                                VAULT_ADDR=${vaultAddr} vault operator raft snapshot restore -force "\$SNAP_FILE"
                                rm -f "\$SNAP_FILE"

                                sleep 5
                                VAULT_ADDR=${vaultAddr} vault status || true
                            """
                        }
                    }
                }
            } finally {
                cleanWs()
            }
        }
    }
}

def buildVaultOpsImage() {
    stage('Build Docker Image') {
        return docker.build("vault-ops:${env.BUILD_TAG}", ".")
    }
}
