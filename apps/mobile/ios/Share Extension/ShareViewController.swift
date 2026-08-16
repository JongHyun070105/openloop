final class ShareViewController: RSIShareViewController {
    override func shouldAutoRedirect() -> Bool {
        true
    }

    override func presentationAnimationDidFinish() {
        super.presentationAnimationDidFinish()
        navigationController?.navigationBar.topItem?.rightBarButtonItem?.title = "OpenLoop"
    }
}
