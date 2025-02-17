//
// Copyright 2022 New Vector Ltd
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import CommonKit
import Foundation

struct UserSessionsFlowCoordinatorParameters {
    let session: MXSession
    let router: NavigationRouterType
}

final class UserSessionsFlowCoordinator: Coordinator, Presentable {
    private let parameters: UserSessionsFlowCoordinatorParameters
    private let allSessionsService: UserSessionsOverviewService
    
    private let navigationRouter: NavigationRouterType
    private var reauthenticationPresenter: ReauthenticationCoordinatorBridgePresenter?
    private var errorPresenter: MXKErrorPresentation
    private var indicatorPresenter: UserIndicatorTypePresenterProtocol
    private var loadingIndicator: UserIndicator?
    
    /// The root coordinator for user session management.
    private weak var sessionsOverviewCoordinator: UserSessionsOverviewCoordinator?
    
    // Must be used only internally
    var childCoordinators: [Coordinator] = []
    var completion: (() -> Void)?
    
    init(parameters: UserSessionsFlowCoordinatorParameters) {
        self.parameters = parameters
        
        let dataProvider = UserSessionsDataProvider(session: parameters.session)
        allSessionsService = UserSessionsOverviewService(dataProvider: dataProvider)
        
        navigationRouter = parameters.router
        errorPresenter = MXKErrorAlertPresentation()
        indicatorPresenter = UserIndicatorTypePresenter(presentingViewController: parameters.router.toPresentable())
    }
    
    // MARK: - Private
    
    private func pushScreen(with coordinator: Coordinator & Presentable) {
        add(childCoordinator: coordinator)
        
        navigationRouter.push(coordinator, animated: true, popCompletion: { [weak self] in
            self?.remove(childCoordinator: coordinator)
        })
        
        coordinator.start()
    }
    
    private func createUserSessionsOverviewCoordinator() -> UserSessionsOverviewCoordinator {
        let parameters = UserSessionsOverviewCoordinatorParameters(session: parameters.session,
                                                                   service: allSessionsService)
        
        let coordinator = UserSessionsOverviewCoordinator(parameters: parameters)
        coordinator.completion = { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .verifyCurrentSession:
                self.showCompleteSecurity()
            case let .renameSession(sessionInfo):
                self.showRenameSessionScreen(for: sessionInfo)
            case let .logoutOfSession(sessionInfo):
                self.showLogoutConfirmation(for: sessionInfo)
            case let .openSessionOverview(sessionInfo: sessionInfo):
                self.openSessionOverview(sessionInfo: sessionInfo)
            case let .openOtherSessions(sessionInfos: sessionInfos, filter: filter):
                self.openOtherSessions(sessionInfos: sessionInfos, filterBy: filter)
            case .linkDevice:
                self.openQRLoginScreen()
            }
        }
        return coordinator
    }
    
    private func openSessionDetails(sessionInfo: UserSessionInfo) {
        let coordinator = createUserSessionDetailsCoordinator(sessionInfo: sessionInfo)
        pushScreen(with: coordinator)
    }
    
    private func createUserSessionDetailsCoordinator(sessionInfo: UserSessionInfo) -> UserSessionDetailsCoordinator {
        let parameters = UserSessionDetailsCoordinatorParameters(sessionInfo: sessionInfo)
        return UserSessionDetailsCoordinator(parameters: parameters)
    }
    
    private func openSessionOverview(sessionInfo: UserSessionInfo) {
        let coordinator = createUserSessionOverviewCoordinator(sessionInfo: sessionInfo)
        coordinator.completion = { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .openSessionDetails(sessionInfo: sessionInfo):
                self.openSessionDetails(sessionInfo: sessionInfo)
            case let .verifySession(sessionInfo):
                if sessionInfo.isCurrent {
                    self.showCompleteSecurity()
                } else {
                    self.showVerification(for: sessionInfo)
                }
            case let .renameSession(sessionInfo):
                self.showRenameSessionScreen(for: sessionInfo)
            case let .logoutOfSession(sessionInfo):
                self.showLogoutConfirmation(for: sessionInfo)
            }
        }
        pushScreen(with: coordinator)
    }

    /// Shows the QR login screen.
    private func openQRLoginScreen() {
        let service = QRLoginService(client: parameters.session.matrixRestClient,
                                     mode: .authenticated)
        let parameters = AuthenticationQRLoginStartCoordinatorParameters(navigationRouter: navigationRouter,
                                                                         qrLoginService: service)
        let coordinator = AuthenticationQRLoginStartCoordinator(parameters: parameters)
        coordinator.callback = { [weak self, weak coordinator] _ in
            guard let self = self, let coordinator = coordinator else { return }
            self.remove(childCoordinator: coordinator)
        }

        pushScreen(with: coordinator)
    }
    
    private func createUserSessionOverviewCoordinator(sessionInfo: UserSessionInfo) -> UserSessionOverviewCoordinator {
        let parameters = UserSessionOverviewCoordinatorParameters(session: parameters.session,
                                                                  sessionInfo: sessionInfo,
                                                                  sessionsOverviewDataPublisher: allSessionsService.overviewDataPublisher)
        return UserSessionOverviewCoordinator(parameters: parameters)
    }
    
    private func openOtherSessions(sessionInfos: [UserSessionInfo], filterBy filter: UserOtherSessionsFilter) {
        let title = filter == .all ? VectorL10n.userSessionsOverviewOtherSessionsSectionTitle : VectorL10n.userOtherSessionSecurityRecommendationTitle
        let coordinator = createOtherSessionsCoordinator(sessionInfos: sessionInfos,
                                                         filterBy: filter,
                                                         title: title)
        coordinator.completion = { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .openSessionDetails(sessionInfo: session):
                self.openSessionDetails(sessionInfo: session)
            }
        }
        pushScreen(with: coordinator)
    }
    
    private func createOtherSessionsCoordinator(sessionInfos: [UserSessionInfo],
                                                filterBy filter: UserOtherSessionsFilter,
                                                title: String) -> UserOtherSessionsCoordinator {
        let parameters = UserOtherSessionsCoordinatorParameters(sessionInfos: sessionInfos,
                                                                filter: filter,
                                                                title: title)
        return UserOtherSessionsCoordinator(parameters: parameters)
    }
    
    /// Shows a confirmation dialog to the user to sign out of a session.
    private func showLogoutConfirmation(for sessionInfo: UserSessionInfo) {
        // Use a UIAlertController as we don't have confirmationDialog in SwiftUI on iOS 14.
        let alert = UIAlertController(title: VectorL10n.signOutConfirmationMessage, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: VectorL10n.signOut, style: .destructive) { [weak self] _ in
            self?.showLogoutAuthentication(for: sessionInfo)
        })
        alert.addAction(UIAlertAction(title: VectorL10n.cancel, style: .cancel))
        alert.popoverPresentationController?.sourceView = toPresentable().view
        
        navigationRouter.present(alert, animated: true)
    }
    
    /// Prompts the user to authenticate (if necessary) in order to log out of a specific session.
    private func showLogoutAuthentication(for sessionInfo: UserSessionInfo) {
        startLoading()
        
        let deleteDeviceRequest = AuthenticatedEndpointRequest.deleteDevice(sessionInfo.id)
        let coordinatorParameters = ReauthenticationCoordinatorParameters(session: parameters.session,
                                                                          presenter: navigationRouter.toPresentable(),
                                                                          title: VectorL10n.deviceDetailsDeletePromptTitle,
                                                                          message: VectorL10n.deviceDetailsDeletePromptMessage,
                                                                          authenticatedEndpointRequest: deleteDeviceRequest)
        let presenter = ReauthenticationCoordinatorBridgePresenter()
        presenter.present(with: coordinatorParameters, animated: true) { [weak self] authenticationParameters in
            self?.finalizeLogout(of: sessionInfo, with: authenticationParameters)
            self?.reauthenticationPresenter = nil
        } cancel: { [weak self] in
            self?.stopLoading()
            self?.reauthenticationPresenter = nil
        } failure: { [weak self] error in
            guard let self = self else { return }
            self.stopLoading()
            self.errorPresenter.presentError(from: self.toPresentable(), forError: error, animated: true, handler: { })
            self.reauthenticationPresenter = nil
        }

        reauthenticationPresenter = presenter
    }
    
    /// Finishes the logout process by deleting the device from the user's account.
    /// - Parameters:
    ///   - sessionInfo: The `UserSessionInfo` for the session to be removed.
    ///   - authenticationParameters: The parameters from performing interactive authentication on the `devices` endpoint.
    private func finalizeLogout(of sessionInfo: UserSessionInfo, with authenticationParameters: [String: Any]?) {
        parameters.session.matrixRestClient.deleteDevice(sessionInfo.id,
                                                         authParameters: authenticationParameters ?? [:]) { [weak self] response in
            guard let self = self else { return }
            
            self.stopLoading()

            guard response.isSuccess else {
                MXLog.debug("[UserSessionsFlowCoordinator] Delete device (\(sessionInfo.id)) failed")
                if let error = response.error {
                    self.errorPresenter.presentError(from: self.toPresentable(), forError: error, animated: true, handler: { })
                } else {
                    self.errorPresenter.presentGenericError(from: self.toPresentable(), animated: true, handler: { })
                }
                
                return
            }

            self.popToSessionsOverview()
        }
    }
    
    private func showRenameSessionScreen(for sessionInfo: UserSessionInfo) {
        let parameters = UserSessionNameCoordinatorParameters(session: parameters.session, sessionInfo: sessionInfo)
        let coordinator = UserSessionNameCoordinator(parameters: parameters)
        
        coordinator.completion = { [weak self, weak coordinator] result in
            guard let self = self, let coordinator = coordinator else { return }
            switch result {
            case .sessionNameUpdated:
                self.allSessionsService.updateOverviewData { [weak self] _ in
                    self?.navigationRouter.dismissModule(animated: true, completion: nil)
                    self?.remove(childCoordinator: coordinator)
                }
            case .cancel:
                self.navigationRouter.dismissModule(animated: true, completion: nil)
                self.remove(childCoordinator: coordinator)
            }
        }
        
        add(childCoordinator: coordinator)
        let modalRouter = NavigationRouter(navigationController: RiotNavigationController())
        modalRouter.setRootModule(coordinator)
        coordinator.start()
        
        navigationRouter.present(modalRouter, animated: true)
    }
    
    /// Shows a prompt to the user that it is not possible to verify
    /// another session until the current session has been verified.
    private func showCannotVerifyOtherSessionPrompt() {
        let alert = UIAlertController(title: VectorL10n.securitySettingsCompleteSecurityAlertTitle,
                                      message: VectorL10n.securitySettingsCompleteSecurityAlertMessage,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: VectorL10n.later, style: .cancel))
        alert.addAction(UIAlertAction(title: VectorL10n.ok, style: .default) { [weak self] _ in
            self?.showCompleteSecurity()
        })
        
        navigationRouter.present(alert, animated: true)
    }
    
    /// Shows the Complete Security modal for the user to verify their current session.
    private func showCompleteSecurity() {
        AppDelegate.theDelegate().presentCompleteSecurity(for: parameters.session)
    }
    
    /// Shows the verification screen for the specified session.
    private func showVerification(for sessionInfo: UserSessionInfo) {
        if sessionInfo.verificationState == .unknown {
            showCannotVerifyOtherSessionPrompt()
            return
        }
        
        let coordinator = UserVerificationCoordinator(presenter: toPresentable(),
                                                      session: parameters.session,
                                                      userId: parameters.session.myUserId,
                                                      userDisplayName: nil,
                                                      deviceId: sessionInfo.id)
        coordinator.delegate = self
        
        add(childCoordinator: coordinator)
        coordinator.start()
    }
    
    /// Pops back to the root coordinator in the session management flow.
    private func popToSessionsOverview() {
        guard let sessionsOverviewCoordinator = sessionsOverviewCoordinator else { return }
        navigationRouter.popToModule(sessionsOverviewCoordinator, animated: true)
    }
    
    /// Show an activity indicator whilst loading.
    private func startLoading() {
        loadingIndicator = indicatorPresenter.present(.loading(label: VectorL10n.loading, isInteractionBlocking: true))
    }

    /// Hide the currently displayed activity indicator.
    private func stopLoading() {
        loadingIndicator = nil
    }
    
    // MARK: - Public
    
    func start() {
        MXLog.debug("[UserSessionsFlowCoordinator] did start.")
        
        let rootCoordinator = createUserSessionsOverviewCoordinator()
        rootCoordinator.start()
        
        add(childCoordinator: rootCoordinator)
        
        if navigationRouter.modules.isEmpty == false {
            navigationRouter.push(rootCoordinator, animated: true, popCompletion: { [weak self] in
                self?.remove(childCoordinator: rootCoordinator)
                self?.completion?()
            })
        } else {
            navigationRouter.setRootModule(rootCoordinator) { [weak self] in
                self?.remove(childCoordinator: rootCoordinator)
                self?.completion?()
            }
        }
        
        sessionsOverviewCoordinator = rootCoordinator
    }
    
    func toPresentable() -> UIViewController {
        navigationRouter.toPresentable()
    }
}

// MARK: CrossSigningSetupCoordinatorDelegate

extension UserSessionsFlowCoordinator: CrossSigningSetupCoordinatorDelegate {
    func crossSigningSetupCoordinatorDidComplete(_ coordinator: CrossSigningSetupCoordinatorType) {
        // The service is listening for changes so there's nothing to do here.
        remove(childCoordinator: coordinator)
    }
    
    func crossSigningSetupCoordinatorDidCancel(_ coordinator: CrossSigningSetupCoordinatorType) {
        remove(childCoordinator: coordinator)
    }
    
    func crossSigningSetupCoordinator(_ coordinator: CrossSigningSetupCoordinatorType, didFailWithError error: Error) {
        remove(childCoordinator: coordinator)
        errorPresenter.presentError(from: toPresentable(), forError: error, animated: true, handler: { })
    }
}

// MARK: UserVerificationCoordinatorDelegate

extension UserSessionsFlowCoordinator: UserVerificationCoordinatorDelegate {
    func userVerificationCoordinatorDidComplete(_ coordinator: UserVerificationCoordinatorType) {
        // The service is listening for changes so there's nothing to do here.
        remove(childCoordinator: coordinator)
    }
}
