// Vault Cluster - tofu plan (scripted pipeline)

def envName = env.JOB_NAME.split('/')[1]

properties([
    parameters([
        string(name: 'TARGET', defaultValue: '', description: 'Optional: -target=module.xxx (leave empty for full plan)')
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

                stage('Plan') {
                    withAwsAuth(envName, img) {
                        def targetArg = params.TARGET ? "-target=${params.TARGET}" : ''
                        sh "./scripts/env.sh ${envName} plan ${targetArg}"
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
