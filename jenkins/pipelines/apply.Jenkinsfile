// Vault Cluster - tofu apply (scripted pipeline)

def envName = env.JOB_NAME.split('/')[1]

properties([
    parameters([
        string(name: 'TARGET', defaultValue: '', description: 'Optional: -target=module.xxx (leave empty for full apply)'),
        booleanParam(name: 'AUTO_APPROVE', defaultValue: false, description: 'Skip interactive approval (use with caution)')
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
                def targetArg = params.TARGET ? "-target=${params.TARGET}" : ''

                stage('Plan') {
                    withAwsAuth(envName, img) {
                        sh "./scripts/env.sh ${envName} plan ${targetArg}"
                    }
                }

                if (!params.AUTO_APPROVE) {
                    stage('Approve') {
                        input message: "Apply changes to ${envName}?", ok: 'Apply'
                    }
                }

                stage('Apply') {
                    withAwsAuth(envName, img) {
                        sh "./scripts/env.sh ${envName} apply -auto-approve ${targetArg}"
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
