// Vault Cluster - Store Credentials in Secrets Manager (scripted pipeline)
// Writes root token and recovery keys TO Secrets Manager (not reads from it).

def envName = env.JOB_NAME.split('/')[1]
def clusterName = "vault-${envName}"

properties([
    parameters([
        password(name: 'ROOT_TOKEN', defaultValue: '', description: 'Vault root token'),
        password(name: 'RECOVERY_KEY_1', defaultValue: '', description: 'Recovery key 1'),
        password(name: 'RECOVERY_KEY_2', defaultValue: '', description: 'Recovery key 2'),
        password(name: 'RECOVERY_KEY_3', defaultValue: '', description: 'Recovery key 3'),
        password(name: 'RECOVERY_KEY_4', defaultValue: '', description: 'Recovery key 4'),
        password(name: 'RECOVERY_KEY_5', defaultValue: '', description: 'Recovery key 5'),
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

                if (params.ROOT_TOKEN?.trim()) {
                    stage('Store Root Token') {
                        // Write token to temp file to avoid exposing in shell args
                        writeFile file: '.root-token.json', text: groovy.json.JsonOutput.toJson([token: params.ROOT_TOKEN])
                        withAwsAuth(envName, img) {
                            sh """
                                aws secretsmanager put-secret-value \
                                    --secret-id "${clusterName}/vault/root-token" \
                                    --secret-string file://.root-token.json

                                rm -f .root-token.json
                                echo "Root token stored in Secrets Manager."
                            """
                        }
                        sh "rm -f .root-token.json"
                    }
                }

                def keys = [
                    params.RECOVERY_KEY_1,
                    params.RECOVERY_KEY_2,
                    params.RECOVERY_KEY_3,
                    params.RECOVERY_KEY_4,
                    params.RECOVERY_KEY_5,
                ].findAll { it?.trim() }

                if (keys.size() > 0) {
                    stage('Store Recovery Keys') {
                        writeFile file: '.recovery-keys.json', text: groovy.json.JsonOutput.toJson([keys_base64: keys])
                        withAwsAuth(envName, img) {
                            sh """
                                aws secretsmanager put-secret-value \
                                    --secret-id "${clusterName}/vault/recovery-keys" \
                                    --secret-string file://.recovery-keys.json

                                rm -f .recovery-keys.json
                                echo "${keys.size()} recovery keys stored in Secrets Manager."
                            """
                        }
                        sh "rm -f .recovery-keys.json"
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
